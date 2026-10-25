Exported 2026-10-23 from the completed Repo MCP architecture pass.

- Execution surface: ChatGPT web
- Coordinator: Codex
- Verified profile: architecture / Pro
- Repository evidence: read-only Repo MCP inspect workspace, historical source refs pinned to the report's identities
- Run ID: `7181894a-3d25-49a4-958a-89a65210b957`
- Conversation: https://chatgpt.com/c/6adbb534-046c-83e8-aae9-d7e253b32de4 (archived after completion)
- Coordinator lifecycle: reused the sole safe existing task and rebound its stale HEAD to the reviewed local main; no protected participant/owner was displaced. The reused task was not finished by this pass.
- Output source: `mcp-report`
- Original output SHA-256: `7ddbe1f63d1dacfd82de3f2382166f6f4fdb8980216bfa3b9264a04a351002ec`
- Submitted plan SHA-256: `afc68412f124af2630aeaff6720ae8066fa2314970d1ec11fe37355b4b8aafea`

This is the independent report on the submitted draft, before the coordinator's subsequent amendments. Its original verdict is preserved. The readable export removes only non-Markdown UI citation markers; the original report remains in Repo MCP's local run archive. It is not a second approval of the revised plan. Platform/dependency documentation statements are the reviewer's findings; no runtime, install or release checks were run.

---

# macOS CLI shipping plan — independent architecture review

## Verdict on direction and readiness

**The direction is sound; the plan needs revision before implementation.** A macOS-first `agent-sessions` CLI for Codex, Claude Code and OpenCode is a useful, bounded product. Shipping it inside the existing signed/notarized app is credible. Keep the TUI, additional CLI providers, stats, pricing and quota features in later phases.

The blocking gaps are contracts, not a reason to abandon the approach: current parsers can return incomplete sessions as success; cache ownership is not scoped to roots; shared search code reaches app-owned caches; pagination revisions are underspecified; and the proposed hard memory ceiling has no demonstrated enforcement mechanism.

This is an architecture/planning verdict. It grants no coding authority and establishes no implementation or release readiness.

## Evidence and scope

Repository evidence came exclusively from Repo MCP.

| Label | Exact evidence identity |
| --- | --- |
| **M** | Current source: `3c5a3324ffe6f89ca38e00d97c5f06a1e76c703e` |
| **P77** | PR #77 head: `4b546dccceaa5862d36453979100026ca37d7353` |
| **B** | PR #77 supplied common base: `ad06d49c2fefdc5db5149259ca9ae1237cd4d626` |
| **C1** | Final companion head: `4c51ca4d8726f430a820dbb9b0ee18d41e88f772` |
| **Plan** | Live `docs/plans/2026-10-23-macos-cli-shipping-plan.md`, lines 1–133; SHA-256 `afc68412f124af2630aeaff6720ae8066fa2314970d1ec11fe37355b4b8aafea` |

References below use these exact commit labels, followed by path and line numbers.

The workspace matched `agent-sessions` / `agent-sessions-crash-coalition-review-20261022`, inspect mode, root `/Users/alexm/Repository/Codex-History`, branch `main`. HEAD remained **M** on the final check. The workspace reports **phase_only** assurance; code evidence was pinned explicitly through historical-ref reads. Historical reads worked, including paths absent from current main. B→P77 Package.swift and P77→C1 CLI comparisons were also read.

The complete live plan, `agents.md`, `CLAUDE.md`, and newest RepoHandover entry were read. `PROGRESS.md` was not exposed by the service. The newest handover is dated 2026-10-21; its release/test statements are historical evidence. Additional concurrent auth/quota/UI edits appeared during the review; all live code diffs, including the specifically excluded files, were excluded. The plan digest remained unchanged.

Coverage included the requested historical CLI/TUI and companion contract/CI files, current provider/descriptor/parser seams, refresh mapping, ingest failures/reconciliation, IndexDB opening/schema, telemetry dependencies and release/project architecture. This was a bounded integration audit, not a line-by-line audit of all 110 historical changed files.

## Severity-ranked findings

### 1. P1 — Define strict parse and ingest outcomes before promising “no false success”

**Plan blocker.** Readability preflight and a JSON error envelope cannot recover failure information that the shared parser API discards.

At M, Codex's public full parser returns only `.session`; a later read error sets a hidden failure flag and appends an ordinary error event before returning that session. Claude uses a JSONL reader whose default turns a chunk-read exception into termination. OpenCode's v1 SQLite transcript and part loops can return prefixes without requiring a final `SQLITE_DONE`.

Evidence:

- `M:AgentSessions/Services/SessionIndexer.swift:2337–2343,2445–2449,2490–2495`.
- `M:AgentSessions/Services/ClaudeSessionParser.swift:32–38,63–68`; `M:AgentSessions/Utilities/JSONLReader.swift:10–19,137–139,182–194`.
- `M:AgentSessions/OpenCode/OpenCodeSqliteReader.swift:1209–1247,1378–1396`. The stronger v2 completion checks at 1476–1500 and 1633–1636 are useful precedents.
- `C1:cli/as-core/Commands.swift:198–245`; `C1:docs/cli-history-retrieval.md:54–59` acknowledges partial/parser-error success.

Ingest has the same reporting problem. It counts parse/write failures as skipped, keeps failure state internally, and returns a Progress without that state. A transaction failure is even collapsed into `.parseFailed`. This prevents a command wrapper from reliably deciding its exit status.

Evidence: `M:AgentSessions/Search/SearchIngestService.swift:102–119,523–537,609–629,668–684,795–816`.

**Required revision:** introduce a strict `ParseOutcome` carrying completion, diagnostics, the input revision and consumed-work counters. Distinguish complete/recognized filtering from malformed-record omissions, I/O/decode/SQL failure, cancellation and budget exhaustion. A historical provider error message remains legitimate content; infrastructure errors must be represented separately.

Add a `RefreshReport` with explicit discovery, parse, write and reconciliation outcomes per scope. Retain useful confirmed updates on partial index runs, but exit nonzero and preserve the previous successful-refresh marker. For `read`, publish no successful page until its selected snapshot has completed and passed validation. Existing app wrappers can retain their current presentation behavior.

### 2. P1 — Root ownership and cache identity require a concrete schema, not just URL injection

**Plan blocker.** The current app reconciles ownership per provider. Reusing that directly can make a successful scan of root B retire rows previously owned by root A. It also assumes bare session IDs are globally unique in important tables.

Evidence:

- `M:AgentSessions/Indexing/DB.swift:198–215`: `files.path` and `session_meta.session_id` are primary keys.
- `M:AgentSessions/Indexing/DB.swift:2174–2180`: an ID conflict updates source and path.
- `M:AgentSessions/Indexing/DB.swift:934–969,980–989,2444–2475`: ownership is source-scoped and reconciliation includes previous storage paths.
- `M:AgentSessions/Search/SearchIngestService.swift:587–608`: the identity snapshot is expanded into owned paths.

The root contract also differs among the first three providers. Codex may include sibling `archived_sessions`; Claude can append Desktop roots even with a custom root; OpenCode accepts several equivalent storage-layout paths.

Evidence: `M:AgentSessions/Services/SessionDiscovery.swift:90–135,441–448,537–582`; `M:AgentSessions/OpenCode/OpenCodeBackendDetector.swift:18–65`.

**Required revision:** specify a normalized source scope and carry it through cache keys, ownership, queries, diagnostics and references. Use a composite identity such as `(scopeID, nativeSessionID)`, preserving the native ID separately. A source scope should represent the configured logical root set; a backend transition inside that scope should have explicit migration/replacement semantics rather than accidentally becoming an unrelated root.

Document each provider's accepted `--root` meaning. Explicit roots should bound discovery; expose any intentionally included sibling/Desktop roots. Preserve Codex's canonical `.jsonl` locator across compression/restoration.

An authoritative empty snapshot may reconcile only its owned scope. Missing, unreadable, partial or cancelled scopes retain prior confirmed rows. Enumeration adapters themselves need completion/error results: existing array-returning discovery is insufficient. See `M:AgentSessions/Services/SessionDiscovery.swift:98–123,464–488,616–622` and `M:AgentSessions/Services/OpenCodeSessionDiscovery.swift:68–87`.

Keep these changes scoped to the CLI cache and shared policy seams; do not turn phase one into an unnecessary migration of every GUI database table.

### 3. P1 — The proposed headless boundary still reaches app runtime and app-owned caches

**Plan blocker.** “No AppKit imports” is a useful build check but is not an isolation guarantee.

Current descriptors combine UI, telemetry factories, parser dispatch and revision hooks. OpenCode's SQLite reader also contains telemetry implementation in the same source file. More significantly, SearchIngestService constructs an app image-cache object and runs a migration that can invalidate files in that cache.

Evidence:

- `M:AgentSessions/Model/SessionSourceDescriptor.swift:272–312,341–369`.
- `M:AgentSessions/OpenCode/OpenCodeSqliteReader.swift:5–50,149–190,1160–1247`.
- `M:AgentSessions/Telemetry/SessionTelemetryProvider.swift:7–47,60–111`.
- `M:AgentSessions/Search/SearchIngestService.swift:203–230,274–287`.
- `M:AgentSessions/Indexing/DB.swift:3635–3659`.
- `M:AgentSessions/Utilities/ImageBrowserIndexCache.swift:53–58,319–325`: the default directory is the app's ImageBrowser cache and invalidation removes files.

**Required revision:** extract models, storage identity, strict readers and refresh policy; inject host effects. App appearance, runtime factories, telemetry execution, image-cache invalidation and archive policy remain app-owned. The CLI must supply an inert app-cache policy and use text stream readers rather than Codex's writable random-access materialization facility (`M:AgentSessions/Utilities/CodexRolloutStorage.swift:237–273`).

A small headless library plus executable is sufficient initially. Foundation, SQLite, CryptoKit and libzstd are legitimate dependencies; UI frameworks and telemetry execution are not. Xcode may continue compiling the same shared source files in place.

Keep all **17 app providers** and their order, lazy appearance closures and runtime factories. The app catalog is not the CLI support list: P77's catalog references every provider, and its drivers automatically adopt discoverable entries. A three-provider CLI should receive an explicit catalog without requiring every app adapter to link into it.

Evidence: `M:AgentSessions/Model/SessionSourceRegistry.swift:31–69`; `P77:AgentSessions/Model/SessionSourceDescriptorCatalog.swift:5–29`; `P77:cli/as-core/Drivers.swift:9–14,43`. Preserve URL-specific identity dispatch, particularly `M:AgentSessions/Model/OpenClawSourceDescriptor.swift:67–72` and its discovery ownership contracts at `M:AgentSessions/Services/OpenClawSessionDiscovery.swift:121–139,394–439`.

### 4. P1 — Cache open modes, schema ownership and cross-process publication need explicit rules

**Plan blocker.** P77's explicit database URL is useful, but its initializer still creates directories, opens read/write, changes pragmas and bootstraps schema. Current main has the same creating/bootstrap behavior for the app index.

Evidence: `P77:AgentSessions/Indexing/DB.swift:38–65,87–95`; `M:AgentSessions/Indexing/DB.swift:132–159,185–193`.

The plan correctly requires missing/newer-cache errors and read-only queries, but must specify the mechanism:

- Separate `openExistingReadOnly` from `openOwnedCacheForIndex`.
- Validate a CLI application/cache marker and schema version before migrations or journal changes. Reject an existing unrecognized database, including an app or provider database supplied through `--db`.
- Handle symlink/hard-link aliases by file identity and ownership validation, not string comparison alone.
- Only `index` creates/migrates. Newer schemas fail without modification. Define the older-schema migration/rebuild policy and keep schema version separate from parser/search-format versions.
- Hold one OS-released writer lock per canonical CLI cache for the complete discovery→update→reconciliation operation. An actor and SQLite's per-transaction lock do not serialize that whole multi-process operation.
- Commit ownership/deletions and refresh status together. Queries use a short consistent read transaction; they must not combine metadata from one publication with a success marker from another.

SQLite WAL allows concurrent readers and a writer, but queries may still return BUSY, and read-only WAL access has sidecar requirements. Define “no cache writes” as no creation, migration or logical mutation, and explicitly address required SQLite bookkeeping. If literal zero filesystem writes is required, fail when that cannot be satisfied. Never use `immutable=1` on changing provider databases. [SQLite WAL](https://www.sqlite.org/wal.html) and [URI documentation](https://www.sqlite.org/uri.html), checked 2026-10-23, support these distinctions.

### 5. P1 — Pagination must bind the returned events to the same complete source snapshot

**Plan blocker.** Plan line 87 promises `HISTORY_CHANGED` without defining the revision's input set, capture point or normalization version.

A file stat is not enough. Current identity revisions use updated time and event count (`M:AgentSessions/Search/SearchIngestService.swift:60–65,186–199`). OpenCode legacy reads include manifest/messages/parts/migration state, Claude Desktop metadata can change returned fields, and SQLite WAL writes need not change the main database file stat.

Evidence: `M:AgentSessions/Services/OpenCodeSessionParser.swift:75–88,106–130,227–238,325–364`; `M:AgentSessions/Services/ClaudeSessionParser.swift:182–221`; `M:AgentSessions/OpenCode/OpenCodeSqliteReader.swift:152–164,858–942,1740–1767`.

**Concrete contract:**

1. Return an opaque versioned revision bound to source scope, logical identity, selected storage/backend, parser-normalization version and the complete relevant input content.
2. Produce revision and events from the same read snapshot. SQLite uses one read transaction for session/messages/parts. File readers bind the selected physical artifact, check replacement/change, and hash the content actually used. Multi-file readers verify the complete input set stayed stable; otherwise retry within budget or fail.
3. Resolve Codex logical `.jsonl` to its selected plain/compressed storage before validation. Keep logical identity stable; conservative revision invalidation on representation changes is acceptable. Evidence: `M:AgentSessions/Utilities/CodexRolloutStorage.swift:8–14,38–49,69–78,100–121`.
4. Require the previous revision for continuation offsets. A mismatch returns `HISTORY_CHANGED` before a success page. Bind event-order-affecting filters to the token. Do not use wall-clock fallback values in deterministic revision/event identity.
5. Define `nextOffset = offset + returnedEvents`. A non-null continuation must advance. Count actual encoded bytes, including metadata, escaping, delimiters and terminal records. A record that cannot fit fails at that offset; it is never skipped. End-of-history returns no continuation.

No durable cursor service is necessary. Re-parsing each bounded session is acceptable initially. A content digest does not by itself make a racing multi-file read atomic; the stability check is part of the contract.

### 6. P2 — Retain output/deadline limits, but replace the unproven hard-RSS promise

**Plan blocker for the claimed guarantee; numerical tuning is a release gate.**

| Proposed limit | Assessment and recommended treatment |
| --- | --- |
| 8 MiB serialized page | Keep as an initial protocol cap. The companion permits five bounded event fields, 200 events and 65,536 bytes per field: approximately 62.5 MiB before JSON escaping at maximum settings. Per-field limits do not replace a page cap. |
| 30-second timeout, adjustable to 300 | Reasonable operational defaults, not measured performance claims. Define this per read/per-session indexing job, including decode and database waits. Do not accidentally give an entire multi-session first index only 30 seconds. |
| 512 MiB decoded input | Not justified as a safe universal allowance. Existing 512 MiB enforcement is specific to whole-buffer compressed decoding; plain reads and the streaming parser do not inherit it. Measure all selected input bytes and allocations. |
| 1 GiB worker resident-memory ceiling | Remove the hard guarantee unless an enforceable mechanism is specified and demonstrated. Use a measured release target or explicitly best-effort watchdog. |

Evidence: `C1:cli/as-core/Commands.swift:39–50,189–211,239–244`; `M:AgentSessions/Utilities/CodexRolloutStorage.swift:18–21,159–176`; `M:AgentSessions/Services/SessionIndexer.swift:2365–2374`.

**Smaller concrete design:** one session job at a time; bounded reader chunks and records; cumulative decoded-byte accounting across every input/SQLite field; an encoded 8 MiB page buffer; and a deadline. For initial qualification, a conservative 64 MiB decoded-input setting is a candidate, not an asserted adequate shipping threshold. Publish the final input/event limits only after the representative corpus demonstrates what ordinary supported histories require. Preserve stricter existing source limits and reject over-budget input explicitly.

Where cancellation cannot be made cooperative, re-execute the same binary as one internal worker. No daemon, worker pool or new service is needed. Drain bounded stdout/stderr concurrently; release public read output only after successful termination, valid response and pipe EOF. Timeout/cancellation must terminate and reap the owned child, including an escalation path and parent-disconnect handling. A worker crash becomes a typed failure, never an empty success.

I found no current official macOS guarantee establishing the proposed exact per-child RSS cap. Apple's archived setrlimit manual and current public XNU header do not substantiate treating RLIMIT_RSS as “kill exactly at 1 GiB”; the header aliases it to RLIMIT_AS. These are evidence limits, not a verified claim about every kernel implementation. [Apple manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setrlimit.2.html); [XNU header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h).

### 7. P2 — Search needs honest freshness and provenance, not just snippets

**Plan clarification needed before freezing the query/schema contract.**

The existing search builder creates a sampled 48,000-character string, including head/middle/tail fragments, and returns only that string. It does not retain event/field/byte attribution. Consequently, adding an FTS snippet does not produce a verifiable event citation.

Evidence: `M:AgentSessions/Search/SessionSearchTextBuilder.swift:164–167,204–232,235–247,295–338`. Historical CLI search emits session metadata: `P77:cli/as-core/Commands.swift:343–362`.

The app's ingest also intentionally delays re-ingest: a 120-second quiet period and 15/45-minute size-based cooldowns rely on a separate app search fallback. Blindly sharing those defaults makes an explicit CLI index appear current while omitting new content.

Evidence: `M:AgentSessions/Search/SearchIngestService.swift:235–240,262–270,461–519`.

**Recommended smaller phase-one contract:** search returns bounded session candidates and sampled-index snippets with `coverage: sampled`, index revision/time, source refresh status and an explicit result-limit indicator. Do not invent event locations; use null/absent event attribution until `read` supplies exact events. If exact event snippets are required in search, add segment provenance during indexing as explicit extra work.

Explicit CLI indexing should use a declared foreground freshness policy rather than inheriting GUI quiet/cooldown defaults. Any deferred changes must remain visible as deferred/stale. Search success means the requested query completed against its disclosed cache snapshot; it never proves absence from full history or that the source is currently unchanged. Use deterministic ordering with a composite-identity tie-breaker.

### 8. P2 — Distribution is viable, but the build graph and cask generator are missing work

**Implementation/release blockers; amend the plan's packaging slice.**

The actual product is `AgentSessions.app`, not Plan line 101's `Agent Sessions.app`. Current Xcode builds the app and test targets; the app has no CLI target dependency or copy phase. The release script builds only the app and then signs it.

Evidence: `M:AgentSessions.xcodeproj/project.pbxproj:2813–2905`, especially 2848–2868; `M:tools/release/build_sign_notarize_release.sh:97–99,134–146`. The Release settings use macOS 14 and Swift 5.9 language configuration at `M:AgentSessions.xcodeproj/project.pbxproj:3947–3958`; P77's manifest requires Swift tools 6.0 and language mode 5 at `P77:Package.swift:1,113–145`. Pin a compatible release toolchain explicitly.

Use the stable path **`AgentSessions.app/Contents/Helpers/agent-sessions`**. Add a reproducible CLI build, both architectures, dependency/runtime linkage inspection, copy/embedding, version stamping and individual helper signing before the final app signature. The current `codesign --deep --force` step must not be the only specification of helper signing. Apple's current guidance requires inside-out signing and treats the helper as a separate executable; Developer ID, timestamp, hardened runtime and appropriate entitlements need artifact verification. [Apple signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

**Update the generator in this repository as well as the tap.** `M:tools/release/deploy-agent-sessions.sh:838–897` reconstructs and uploads the entire cask; its template contains the app stanza but no CLI binary stanza. Editing only the external cask would lose the link on a later release. Existing verification at `M:tools/release/verify-deployment.sh:230–255` checks version/URL, not the binary artifact.

Homebrew explicitly supports linking executables inside app bundles, so extending this cask is credible. [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-binary).

Required release evidence includes native arm64 and qualified Intel execution, macOS 14 runtime tests, nested signatures, final notarized/stapled artifact execution, clean install, Sparkle upgrade, cask upgrade/uninstall, custom appdir, path spaces, command collisions and moved/deleted app recovery. Inspect both slices and all native dependencies; universal-file inspection alone is not runtime qualification. Preserve the existing GUI release checks. No installed signing identity, successful notarization or successful test run was established here.

### 9. P2 — Phase-two TUI work must include protocol and process lifecycle changes

**TUI implementation/release blockers, not reasons to delay a qualified CLI.**

The three draft claims are verified:

- ID-only preview/error caching: `P77:tui/main.go:214–225,255–272,407–412`.
- Ignored per-source index errors: `P77:tui/main.go:347–358`.
- Negative preview width reaching `strings.Repeat`: `P77:tui/main.go:229–244`; `P77:tui/header.go:173–203`.

Add the following to phase two:

- Decode tagged records and terminal summaries. Current `P77:tui/core.go:185–218` buffers output, discards partial output on nonzero exit and checks schema without record type.
- Bound the preview cache by bytes and key it by source/scope/identity/revision. Cancel obsolete requests and reject stale completions. The current map is unbounded (`P77:tui/main.go:103–105`) and previews use full `show` output (`P77:tui/core.go:248–260`).
- Sequence refreshes within a view, and bind resume/copy responses to the explicitly selected target. Existing resume/copy messages lack that generation identity (`P77:tui/main.go:59–70,341–345,387–393`).
- Complete child cleanup before terminal handoff. Current quit waits at most three seconds and then may launch; launch uses `sh -c` (`P77:tui/main.go:669–700`).
- Escape untrusted terminal controls, including ANSI/OSC sequences, in history, titles, paths and diagnostics. The current renderer consumes historical strings without that boundary (`P77:tui/render.go:60–111,151–159`).
- Surface sampling, truncation, partial failure and cancellation. Restore the terminal on every exit path; clipboard/OSC52 and launch remain explicit human actions.

Reserve `agent-sessions tui`, use the exact bundled helper path and negotiate protocol compatibility. The display shell string must never become the executable interface; use executable/argv/cwd/environment.

## Ordered revised shipping sequence

1. **Revise and freeze the small contracts first.** Specify source scopes, strict parse/refresh outcomes, CLI cache ownership/versioning, snapshot revisions, typed JSON records/terminal summaries, and resource semantics. Resolve the limited decisions below. This is the missing prerequisite to the current slices.

2. **Extract current leaf code and preserve app adapters.** Start with the current Codex parser/storage/decoder, then the strict Claude and OpenCode paths. Keep app forwarders and DEBUG counters. Separate reusable telemetry value/revision helpers from telemetry execution. Inject host effects. Keep all 17 app registrations and existing provider-specific behavior. Create a headless library/test target and CLI target; avoid a whole-app module migration.

3. **Ship the read contract internally before index orchestration.** Port final C1, then add canonical storage resolution, URL-specific identity dispatch, strict completion, stable revisions, continuation validation, encoded caps and cancellation. Exercise synthetic file/SQLite stores. This gives indexing a trustworthy parser boundary rather than retrofitting it later.

4. **Implement the CLI-owned cache and scoped refresh.** Add explicit open modes and ownership/schema guards. Implement complete/partial/failed discovery for the three sources; reuse normalized revision mapping with host adapters. Add one cross-process writer lock, short transactions, safe reconciliation and durable attempt/success status. Test recovery before adding more commands.

5. **Complete sources/list/search/resume-plan and freeze protocol v1.** Use typed Codable DTOs, total ordering and bounded results. Preserve partial index reporting; never substitute an empty array or `{}` for a failure. Distinguish operation completion from corpus completeness/freshness. Resume returns argv/cwd/environment and capability status without executing a provider. Do not introduce stats tables, pricing aliases or usage sorting.

6. **Qualify the integrated candidate.** Run current app/core/process tests, explain test-inventory changes, compare normalized events and refresh decisions, and measure limits. Cover all three providers' current storage formats. Any real-history pilot must be separately owner-selected and local; it is not part of this review.

7. **Integrate and qualify the single Mac release artifact.** Build/copy/sign the CLI before app signing, update the generated cask and verification, and run artifact/install/update/removal checks. One version and updater remain appropriate. Publication requires the later explicit release authorization already contemplated by the plan.

8. **Build TUI phase two against the frozen CLI.** Implement tagged streaming/partial-state handling, bounded previews, cancellation, terminal-safe rendering and direct-argv launch before polish. Add providers only after lifecycle qualification. Stats/cost can follow through current telemetry and dated-price semantics; neither is required for a useful history TUI.

Stats exclusion is justified by actual coupling: `P77:cli/as-core/Stats.swift:11–12,27–46,79–113` duplicates provider dispatch and pricing work; `P77:cli/as-core/Commands.swift:227–241` adds a usage-write pass. That work is unnecessary for phase-one retrieval.

## Required acceptance criteria

These are required future checks, not reported passes.

| Area | Required evidence |
| --- | --- |
| App preservation | Current app builds; stable XCTest and core tests pass on the final candidate; test counts and test-name removals are explained. All 17 providers remain registered. Preserve Cline paired revisions, DSH v4 selection, Cursor ACP, OpenClaw ownership/provenance, lazy appearance and telemetry behavior. |
| Parse fidelity | Full normalized event/identity parity, not just summary goldens. Inject mid-read/SQL/decode failures, invalid UTF-8, oversized records and malformed JSON. Legitimate history error events remain readable; incomplete infrastructure reads cannot produce complete pages. |
| Scope and lifecycle | Fresh/unchanged/update/same-timestamp-change/delete/delete-to-empty; missing/unreadable/partial roots; BUSY/recovery; root aliases and two roots with duplicate native IDs; backend transitions; cancellation. Failed scope never authorizes deletion elsewhere. |
| Source formats | Codex plain/compressed/both/compress/restore/truncated streams and canonical locators; Claude request logs/subagents/stopped replies/Desktop sidecars as supported; OpenCode legacy multipart/v1 SQLite/v2 SQLite and migration state. Hybrid URL dispatch remains covered for future providers. |
| Cache and concurrency | Missing/older/newer/unrecognized database; app/provider aliases; two indexing processes; reads during indexing; kill before/during commit; ownership/status recovery. No unintended source, app-cache or preference changes. |
| JSON and pagination | Schema/type compatibility; JSON-only stdout; no false empty success; exit 0 for completed operations including zero matches, 1 for runtime/partial failure, 2 for usage; defined signal behavior. UTF-8/escaping/cap boundaries, monotonic continuation, same-size rewrite, WAL changes and parser-version changes. |
| Resources and lifecycle | Measured ordinary/adversarial corpus sizes and peaks; byte/record/event limits; deadline; pipe backpressure/SIGPIPE; bounded stderr; cancellation; no surviving worker after normal quit, timeout or parent disconnect. |
| Release | Final universal app/CLI/dependencies; macOS 14 and Intel runtime evidence; signing/notarization/stapling; CLI works without GUI launch; installed bundle/cask/manual-link behavior; upgrade, removal and location-change recovery. |

The companion's 13 test methods are source inventory, not 13 newly passed tests. Its no-write test checks a Codex file and absence of the CLI database; its SQLite fixture uses Hermes. Its macOS-15/Ubuntu Swift 6.1 workflow is not evidence for current-main OpenCode, Intel or macOS 14 qualification. Evidence: `C1:scripts/as_core_read_contract.py:47–195`; `C1:.github/workflows/as-core-read.yml:20–46`.

Record the actual release SQLite version/vendor fixes. Current SQLite documentation reports a rare concurrent WAL write/checkpoint race fixed in 3.51.3 (2026-03-13), with 3.44.6/3.50.7 backports. This is a dependency check, not evidence that the reviewed app encountered corruption.

Official platform documentation was checked on 2026-10-23; Apple/Homebrew pages are rolling documentation without a published revision date. The release must be tested from the distributed artifact, including fresh and upgrade installations, consistent with [Apple's distribution guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Decisions still needed

Only three choices need explicit resolution in the revised plan:

1. **Root semantics:** adopt explicit bounded provider scopes, including a declared policy for Codex archived siblings and Claude Desktop roots.
2. **Search attribution:** accept sampled candidate snippets with exact event citations supplied by read, or fund segment-provenance storage in phase one. I recommend the former.
3. **Large-history support:** select the published input/event limits from measured corpus evidence; remove the hard RSS promise unless a supported enforcement mechanism is proven.

The initial three-provider scope, public name, separate CLI cache, bundled Mac distribution, deferred TUI and deferred stats do not need reopening.

No edits, builds, tests, coding grants, provider-history network access, private transcript reads, implementation or publication were performed. Historical CI, fixture counts, release records and merge-conflict totals were not certified as fresh execution results.

VERDICT: PLAN NEEDS REVISION