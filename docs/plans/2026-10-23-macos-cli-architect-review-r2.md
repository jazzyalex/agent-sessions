Exported 2026-10-23 from the second Repo MCP architecture pass.

- Execution surface: ChatGPT web
- Coordinator: Codex
- Verified profile: architecture / Pro
- Repository evidence: read-only Repo MCP; source pinned to `3c5a3324ffe6f89ca38e00d97c5f06a1e76c703e`
- Run ID: `6e15febb-a997-403b-8bd9-f8aa1e876e00`
- Conversation: https://chatgpt.com/c/6adbbab2-032c-83e8-b14b-d384a721f873 (archived after completion)
- Output source: `mcp-report`
- Original output SHA-256: `674bc9dcef1695d2b7c5d5dd4bbf466dc165f206626466252989c31f2d4235aa`
- Submitted plan SHA-256: `e36dc989ec2ef11cc9c64f4b01f9aacfe98dd67449b103cc5033b319184e9fea`

This preserves the verdict on the submitted revision, before the coordinator's two subsequent contract amendments. The original report remains in the local Repo MCP archive. No implementation or release checks were run.

---

# Agent Sessions macOS CLI shipping plan — second independent architecture review

Run: `2b10157aaeb0e905`  
Date: 2026-10-23  
Execution surface: ChatGPT web; repository evidence: Repo MCP, inspect mode.

## Decision and product impact

**The revised plan needs two narrow amendments before implementation: a duplicate-identity rule within a configured scope, and a safe SQLite rebuild cutover.** Seven of the nine earlier findings are closed at the planning level. Findings 2 and 4 are substantially addressed but retain the specific gaps below.

The intended product and architecture remain appropriate: a macOS CLI for Codex, Claude Code and OpenCode, a small shared strict-reader library, a separately owned CLI cache, and one bundled Mac distribution. Keep the TUI, additional providers, stats and quota work in later phases. No alternative architecture is necessary. The remaining amendments protect reliable history attribution and cache consistency; they do not require a larger extraction or a new service. [Plan:7–9,97–111,143–149,165–173]

This verdict concerns readiness to implement after owner approval. It grants no coding authority and establishes no implementation, install or release readiness.

## Evidence identity and limits

References use these exact identities:

| Label | Evidence |
| --- | --- |
| **Plan** | Complete live `docs/plans/2026-10-23-macos-cli-shipping-plan.md`, lines 1–182; SHA-256 `e36dc989ec2ef11cc9c64f4b01f9aacfe98dd67449b103cc5033b319184e9fea` |
| **R1** | Complete live `docs/plans/2026-10-23-macos-cli-architect-review.md`, lines 1–277; SHA-256 `9b341644072724b19ae087812ae1e50cd03973020dbb0c3c647a7ad757453130`; prior run `7181894a-3d25-49a4-958a-89a65210b957` |
| **M** | All current-source evidence: `3c5a3324ffe6f89ca38e00d97c5f06a1e76c703e` |
| **P77** | Relevant historical TUI evidence: `4b546dccceaa5862d36453979100026ca37d7353` |
| **C1** | Relevant final companion read implementation: `4c51ca4d8726f430a820dbb9b0ee18d41e88f772` |

Repo MCP verified repository `agent-sessions`, task `agent-sessions-crash-coalition-review-20261022`, root `/Users/alexm/Repository/Codex-History`, branch `main`, and HEAD **M**. The final check still showed **M**. Assurance was **phase_only**, with read-only workspace capability. Source reads explicitly supplied M, P77 or C1; they did not rely on the live working tree.

Both planning documents were untracked live artifacts. The plan matched the submitted digest on the complete paginated read and on the final full-file-hash check; it remained unchanged for this pass. The first report's digest was also unchanged. The dirty worktree included concurrent implementation changes; their live contents and diffs were excluded.

Repository instructions `agents.md`, `CLAUDE.md`, and the newest `RepoHandover.md` entry were read. `PROGRESS.md` was not exposed by policy. Initial `repo_info` calls hit the service's discovery timeout; later identity/status checks succeeded. Plan/report pagination was completed, and no relied-upon source excerpt remains cut off. Coverage was a bounded architecture/integration review, not a re-audit of all 110 historical files. The supplied common-base relationship and historical CI/test/release claims were not newly certified.

## Remaining findings

### 1. P1 — Resolve conflicting native IDs within one configured scope

**Exact plan lines:** 99, 103–107, 123 and 155.

**Gap.** Line 99 hashes the configured logical root set into one scope and keys sessions by `(scopeID, nativeSessionID)`. That separates different root-set namespaces, but does not distinguish conflicting inputs with the same native ID inside one namespace. Multiple roots are admitted, and line 155 asks for duplicate-native-ID tests, but the required result of an intra-scope collision is absent.

**Pinned source evidence:**

- `M:AgentSessions/Services/OpenCodeSessionParser.swift:138–165,227–254` reads a session manifest from its URL and constructs `Session(id: obj.id, filePath: url.path)`. The ID is not qualified by the owning input. Discovery collects matching manifests across the selected tree at `M:AgentSessions/Services/OpenCodeSessionDiscovery.swift:68–87`.
- `M:AgentSessions/OpenCode/OpenCodeSqliteReader.swift:1173–1185` similarly selects a native ID from the chosen database.
- `M:AgentSessions/Services/SessionIndexer.swift:2461–2478` and `M:AgentSessions/Services/ClaudeSessionParser.swift:145–166` currently distinguish path-derived app IDs from internal provider-ID hints. The new contract should preserve that distinction deliberately rather than treating the identifiers as interchangeable.
- `M:AgentSessions/Indexing/DB.swift:2174–2183` demonstrates the existing ID-conflict upsert that replaces path and metadata. The plan correctly avoids copying the GUI schema; its new composite key still needs an explicit collision policy.

**Concrete failure scenario.** Two imported OpenCode stores contain session `ses_X` and have diverged. If configured together in one logical root set, they produce the same `(scopeID, nativeSessionID)`. An implementation can overwrite one candidate's metadata/search text with the other's, or abort on a uniqueness constraint without the intended refresh semantics. Conflicting manifests encountered within one discovered tree present the same key problem. Separate input-ownership rows alone do not make the session row unambiguous.

This is an inference from the specified key and pinned parser identities, not an observed production incident.

**Smallest sufficient amendment.** Keep the proposed schema and adopt a conservative collision rule:

> Resolve all inputs claiming an identity before publishing a replacement for that identity. Proven aliases or provider-defined representations of the same logical input may coalesce. Otherwise, duplicate native IDs from distinct logical inputs produce a typed identity conflict: preserve the prior confirmed row, mark the affected scope partial, return nonzero, and grant no deletion authority for the conflicted ownership. Never choose a winner by enumeration order.

If the product must expose both conflicting histories simultaneously, add a stable root/input discriminator to the cache identity and references while returning the native ID separately. That is optional product scope; rejecting ambiguity is sufficient for phase one.

**Focused acceptance addition:** put duplicate IDs in the *same* configured scope, including copies that later diverge. Verify that neither prior data nor ownership is silently replaced. Two separate invocations with different root-set hashes do not exercise this case.

### 2. P2 — Define an exclusive, SQLite-safe rebuild cutover

**Exact plan lines:** 109–111, 123 and 155.

**Gap.** Line 109 requires rebuilding into a new cache and atomically replacing the selected cache. Line 111 permits concurrent readers and specifies a writer lock. A short read transaction does not guarantee that its database connection is closed. Writer serialization therefore leaves replacement beneath an open reader possible.

**Pinned source and platform evidence:**

- `M:AgentSessions/Indexing/DB.swift:148–163` keeps a connection until object destruction; `186–189` enables WAL. This is relevant context for the proposed shared low-level helpers, not a claim that the unimplemented CLI store already contains this defect.
- SQLite's official [How To Corrupt An SQLite Database File, §2.5–2.6](https://sqlite.org/howtocorrupt.html) documents the danger of replacing an open database pathname: old and new database handles can share pathname-derived journal/WAL files. Its [WAL documentation, §4](https://sqlite.org/wal.html) treats WAL state as part of the database and describes its connection-dependent lifetime. Checked 2026-10-23.

**Concrete failure scenario.** A `list` or `search` process still holds the old cache open. Rebuild holds the sole writer lock and replaces `index.db`; a new process opens the replacement. The old and new generations can now coexist under a pathname and sidecar namespace that no longer identify one database. Atomic filesystem rename alone does not provide a SQLite transaction or coordinate those connections.

**Smallest sufficient amendment.**

> Every cache open participates in replacement coordination. Rebuild cutover blocks new opens, waits boundedly for all existing connections to close or returns CACHE_BUSY, completes the appropriate SQLite checkpoint/close/sidecar lifecycle, and replaces the cache only while that generation is quiescent. The coordination identity survives replacement and is consistent across accepted aliases. The replacement and recovery copy must each retain a coherent database state.

A shared connection-lifetime lease with an exclusive replacement phase is one sufficient implementation. The plan need not prescribe an OS lock primitive. Ordinary queries may remain concurrent with ordinary index transactions. A SQLite-safe transactional rebuild that avoids pathname replacement is another option; a generation service or new daemon is unnecessary.

**Focused acceptance addition:** pause a reader with its connection open, attempt rebuild, and admit another query during cutover. Require bounded waiting/busy behavior, coherent reopen, and recovery after interruption before and after replacement, including WAL-backed candidates. Retain the existing inactive-scope and recovery-copy requirements.

## Closure of the nine earlier findings

“Closed” means the revised implementation plan has adequate semantics. It does not mean its future code or tests have passed.

| Prior finding | Disposition | Basis in the revision |
| --- | --- | --- |
| **1. Strict parse and ingest outcomes** | **Closed for planning** | Plan:85 separates infrastructure failure from historical error content and requires ParseOutcome/RefreshReport. Plan:129 permits only safe complete sessions from a partial index and prevents failed-scope certification. Plan:139,159 require injected failures. |
| **2. Scoped identity and root ownership** | **Substantially addressed; amendment 1 remains** | Plan:99–107 defines bounded provider roots, normalized scopes, per-root authority and retained inactive namespaces. The remaining gap is conflicting IDs *within* one scope. |
| **3. Headless boundary and app-owned effects** | **Closed for planning** | Plan:91,97,138 chooses leaf readers/policy, explicit three-reader CLI registration, compatibility forwarders, all 17 GUI adapters, and exclusion of telemetry execution, image-cache migration, archive mutation and random-access materialization. |
| **4. Cache ownership, open modes and publication** | **Substantially addressed; amendment 2 remains** | Plan:109–111 adequately specifies a dedicated store, ownership/version guards, read-only/index opens, foreign-database rejection, writer serialization and attempt/success publication. Rebuild replacement additionally needs reader-lifetime coordination. |
| **5. Snapshot-bound pagination** | **Closed for planning** | Plan:113,125 binds events and tokens to captured relevant inputs, normalization and options, requires continuation tokens, permits conservative representation invalidation, and defines advancing offsets and encoded caps. Its optimistic multi-file guarantee is stated honestly. |
| **6. Resource limits, deadlines and child lifetime** | **Closed for planning; measurements intentionally pending** | Plan:127–129 removes the hard RSS promise, makes numeric limits provisional, defines per-session deadlines and pre-allocation enforcement, and requires bounded pipe handling, cancellation, escalation, reaping and successful exit/EOF before success. |
| **7. Search provenance and foreground freshness** | **Closed for planning** | Plan:115,131 returns sampled candidate snippets without invented event attribution, discloses freshness/limits, and bypasses GUI quiet/cooldown scheduling for explicit indexing. |
| **8. Build, signing and cask distribution** | **Closed for planning; artifact qualification pending** | Plan:143–149,161 specifies the actual AgentSessions.app helper path, reproducible dual-architecture build, toolchain/version/dependency checks, helper-before-app signing, local cask generator and verification updates, and final install/update/removal/Gatekeeper checks. |
| **9. TUI protocol and process lifecycle** | **Closed for phase-two planning** | Plan:169–171 covers tagged partial output, bounded revision-aware caching, stale async results, paged previews, dimension clamping, terminal escaping, direct argv launch and completed child cleanup. These remain phase-two gates. |

## Source checks supporting those closures

The strict-reader amendment matches the actual failure boundaries: Codex's public wrapper returns only the session while retaining failure internally; Claude uses JSONLReader's non-propagating default; OpenCode v1 message/part loops lack a final completion check, while v2 provides a useful stronger precedent. These are implementation work explicitly required by the revision. [`M:AgentSessions/Services/SessionIndexer.swift:2337–2343,2445–2449,2490–2495`; `M:AgentSessions/Services/ClaudeSessionParser.swift:32–38,63–68`; `M:AgentSessions/Utilities/JSONLReader.swift:10–19,137–139,182–194`; `M:AgentSessions/OpenCode/OpenCodeSqliteReader.swift:1209–1247,1378–1396,1476–1500`]

Likewise, ingest currently hides parse/write failure behind its Progress/skipped presentation, and reaches the app image-cache migration. The dedicated CLI store and injected host effects directly address those paths. [`M:AgentSessions/Search/SearchIngestService.swift:102–119,203–230,274–287,523–537,795–816`; `M:AgentSessions/Indexing/DB.swift:3635–3659`; `M:AgentSessions/Utilities/ImageBrowserIndexCache.swift:53–58,319–325`]

The root table changes are deliberate and sufficient apart from identity collision handling: current Codex discovery adds an archived sibling, current Claude discovery may add Desktop/sibling/default roots, and OpenCode normalizes multiple layouts. The new CLI rules explicitly replace those host defaults without changing the GUI. [`M:AgentSessions/Services/SessionDiscovery.swift:90–135,441–448,537–582`; `M:AgentSessions/OpenCode/OpenCodeBackendDetector.swift:18–65`]

Canonical compressed resolution and the exclusion of writable materialization are grounded in `M:AgentSessions/Utilities/CodexRolloutStorage.swift:38–78,100–121,237–273`. The final companion's physical-file preflight and page emission at `C1:cli/as-core/Commands.swift:185–245` require the specified porting changes; retaining that historical body unchanged would not satisfy the revised plan.

Search's sampled-string construction and GUI scheduling are confirmed at `M:AgentSessions/Search/SessionSearchTextBuilder.swift:164–247,295–338` and `M:AgentSessions/Search/SearchIngestService.swift:232–240,262–270,461–519`. The revision correctly chooses candidate discovery followed by exact read citations.

The full GUI registry and runtime/telemetry coupling are visible at `M:AgentSessions/Model/SessionSourceRegistry.swift:31–69` and `M:AgentSessions/Model/SessionSourceDescriptor.swift:272–312,341–369`. Preserving them while extracting three leaf readers is coherent.

Packaging changes target the actual app scheme and release implementation: `M:AgentSessions.xcodeproj/xcshareddata/xcschemes/AgentSessions.xcscheme:15–20`; `M:tools/release/build_sign_notarize_release.sh:97–99,134–146`; `M:tools/release/deploy-agent-sessions.sh:838–897`; `M:tools/release/verify-deployment.sh:230–255`. Apple [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) supports Contents/Helpers and inside-out signing; the current [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-binary) supports a bundle executable referenced through appdir.

The TUI fixes correspond to its historical ID-only preview cache, buffered/error-discarding process wrapper, optimistic index status and shell handoff: `P77:tui/main.go:214–244,255–272,347–358,669–700`; `P77:tui/core.go:185–220,248–260`.

## Implementation details and acceptance gates that should stay in their existing slices

- **Swift package access:** If files compiled directly by Xcode contain actual `package` declarations, configure their package identity or keep package-facing wrappers separate. [Swift SE-0386](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md), implemented in Swift 5.9, requires `-package-name`; SwiftPM supplies it automatically. This is build wiring for Plan:97,138, not a reason to reject the architecture.
- **Resume adaptation:** The current builders return shell/display strings, including Codex fallback chaining. Extract structured executable/argv/cwd/environment from validated strategy inputs; do not parse the display shell string into execution. Plan:121,131,171 already sets that contract. [`M:AgentSessions/Resume/CodexResumeCommandBuilder.swift:3–8,22–60`; `M:AgentSessions/ClaudeResume/ClaudeResumeCommandBuilder.swift:19–47`; `M:AgentSessions/OpenCodeResume/OpenCodeResumeCommandBuilder.swift:19–41`]
- **Capacity and artifact measurements:** Corpus limits, peak memory, Intel/macOS 14 execution, quarantined/offline behavior and final signatures remain the declared qualification gates. Demanding their results in this read-only planning pass would expand scope. [Plan:127,142–147,155–163]
- **SQLite version qualification:** Keep Plan:155's actual build/vendor-patch check. The official WAL page, updated 2026-08-25, records the WAL-reset fix in SQLite 3.51.3 (2026-03-13), with 3.44.6/3.50.7 backports. This existing acceptance requirement covers dependency qualification; it is not an additional architectural finding. [SQLite WAL §11](https://sqlite.org/wal.html)

Official documentation was checked on 2026-10-23. Apple TN2206 is archived guidance; Homebrew's cookbook is rolling documentation. Current Apple signing/notarization pages exposed limited indexed text through the retrieval tool rather than a complete readable body. No newly identified platform breaking change requires a different distribution architecture. No signing, notarization, runtime or historical CI success is asserted by this review.

## Ordered remaining work

1. Add the intra-scope identity-conflict rule and its focused acceptance case to Plan:99,155.
2. Add the connection-aware rebuild cutover invariant and focused concurrency/recovery case to Plan:109–111,155.
3. Freeze the resulting contract in slice 0, then seek the owner's implementation approval. Preserve the existing order: strict readers and read first; scoped cache/refresh next; public commands; measured qualification; final packaged artifact.
4. Keep phase-two TUI work and release publication under their existing later gates. No further architecture amendment was found within this bounded review.

No edits, builds, tests, coding grants, private provider-history reads, implementation, publication or external messages were performed. This report is the requested planning handoff to the coordinator.

VERDICT: PLAN NEEDS REVISION