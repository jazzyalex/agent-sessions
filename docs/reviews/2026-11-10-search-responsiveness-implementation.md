# Search and responsiveness implementation record

Status: in progress. User authorized implementation on a new branch, with Sol Max reviews
and Luna Max mechanical work. Live profiling, commits and pushes are explicitly excluded.

Branch: `refactor/search-responsiveness`, starting at `042d2aef` with pre-existing dirty files.
Baseline export: `/private/tmp/as-search-responsiveness-baseline-20261110/repo`.
Baseline metadata: `/private/tmp/as-search-responsiveness-baseline-20261110/metadata`.

Plan: [implementation](../superpowers/plans/2026-11-10-search-responsiveness-refactor.md).
Contracts: [specification](../superpowers/specs/2026-11-10-search-responsiveness-refactor.md).
Deferred measurements: [profiling](../superpowers/specs/2026-11-10-search-responsiveness-profiling.md).

## Phase status

| Phase | State | Evidence |
|---|---|---|
| P0 baseline | Captured | Reconstructed source manifest and 4,591 test declarations; see baseline caveat below. |
| P1 credential boundary | Implemented; validating | Serial async service, coalesced cancellable reads, typed writes, UI and client request leases. |
| P2 account ownership | Implemented; validating | Owned caches, persistence and merges; two Sol review passes corrected stale delivery and enablement races. |
| P3 query/extraction | In progress | Native FTS5 unicode61 tokenizer, AST and three-valued matcher; shared semantic event fields. |
| P4 migration/identity | In progress | Required format obligations bypass cooldowns; activation waits for bounded scanners. |
| P5 scanners | Pending | All registry providers and bounded ingestion. |
| P6 Return/UI | Pending | Coverage and lightweight results. |
| P7 instrumentation | Pending | Instrumentation/tests only; live measurement deferred by user. |
| P8 presentation | Pending | Atomic revision-aware derivation. |
| P9 integration | Pending | Build, automated tests, review, documentation. |

## Authorization adjustment

The plan's documentation-only restriction is superseded by the user's implementation request.
P7 baseline live measurement and P9 production profiling gates remain deferred. Preserve the
P0 export so a later measurement can use an unchanged baseline. No implementation result may
claim that the 8,000-message opening delay is fixed without that separately authorized evidence.

## Validation and review

The P1/P2 + query Debug app build succeeded (`/private/tmp/as-search-responsiveness-query-build.log`).
The first focused test build exposed missing credential-service membership in the separate
logic-test target; membership is now corrected and the focused suite is running. No live
profiling or private-corpus measurements have run.

### Baseline caveat

The export was accidentally refreshed after initial P1 edits. The three originally clean
credential files were reconstructed from `042d2aef`; two new post-baseline files were moved
out of the export into metadata quarantine. The authoritative records are
`metadata/BASELINE-RECONSTRUCTION.json`, `metadata/reconstructed-file-manifest.json`, and
`metadata/reconstructed-test-inventory.json` (4,591 declarations). The pre-refresh bytes of
an independently edited monthly summary are unavailable; this documentation-only caveat
does not alter the exported source baseline. Earlier manifests in that folder are superseded.

### Test inventory changes

The source-manager tests now inject an OAuth owner resolver and inert scheduler. Three names
changed to express ownership semantics: persisted tmux source restoration becomes rejection
of an unowned tmux snapshot; recent/expired tmux merge cases become same-owner window cases.
Four additional source-manager cases cover unowned/wrong-owner restoration and merges.
New service, integration and query tests preserve the prior unrelated test declarations.
