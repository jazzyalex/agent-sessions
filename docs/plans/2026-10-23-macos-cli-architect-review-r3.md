Exported 2026-10-23 from the focused Repo MCP architecture confirmation.

- Execution surface: ChatGPT web
- Coordinator: Codex
- Verified profile: architecture / Pro
- Repository evidence: read-only Repo MCP inspect; source pinned to `3c5a3324ffe6f89ca38e00d97c5f06a1e76c703e`
- Run ID: `a63fe5f6-a633-4082-9644-608f17cb04bd`
- Conversation: https://chatgpt.com/c/6adbbf2b-da28-83e8-8e3f-b2258f3ab60c (archived after completion)
- Output source: `mcp-report`
- Original output SHA-256: `9fa82c471be965b6a4a30417fe86a179606c5ca92860bda7b3ddcf9f89aa4f63`
- Reviewed plan SHA-256: `ca9576904dde42da1e12f633e0b5af55cd95077458e95800a75cc887840a8ba8`

This verdict approves the implementation plan after the two amendments requested in round two. It grants no implementation or release authority. The original report remains in the local Repo MCP archive. After confirmation, only plan status/review provenance was updated; substantive contract content stayed unchanged.

---

# Agent Sessions CLI — focused architecture confirmation

Run: `a608c4779e636508` · 2026-10-23  
Repository/task: `agent-sessions` / `agent-sessions-crash-coalition-review-20261022`

**Both remaining findings from the second report are closed for planning. The explicit identity-field mapping introduces no concrete contradiction.** The plan is ready to implement after separate owner approval. This review grants no coding authority or code/release approval.

## Evidence identity

- **P** = complete live `docs/plans/2026-10-23-macos-cli-shipping-plan.md`, 198 lines, 48,381 bytes. SHA-256: `ca9576904dde42da1e12f633e0b5af55cd95077458e95800a75cc887840a8ba8`. Both read pages and the final full-file hash matched the submitted digest.
- **R2** = complete live `docs/plans/2026-10-23-macos-cli-architect-review-r2.md`, 149 lines. SHA-256: `1e4616c036a20e3530d7a3e985915ff6a90670fecc86f5899706d8dc2fed642c`, unchanged at final verification. Its export identifies prior pass `6e15febb-a997-403b-8bd9-f8aa1e876e00`. [R2:1–13]
- **M** = `3c5a3324ffe6f89ca38e00d97c5f06a1e76c703e`. Initial and final `repo_info` verified root `/Users/alexm/Repository/Codex-History`, branch `main`, and HEAD M. HEAD did not move. Workspace mode was `inspect`, read-only, with `phase_only` assurance and no candidate digest. Every code read explicitly used M; concurrent live implementation changes were excluded.
- Repository instructions `agents.md`, `CLAUDE.md`, and the newest pinned `RepoHandover.md` entry were read. Optional `PROGRESS.md` was absent at M and unavailable through the live policy. Both requested planning documents were accessible and read completely.

## Closure table

| Review item | Disposition | Why the amendment is sufficient |
| --- | --- | --- |
| **R2 finding 1 — conflicting identities within one scope** | **Closed for planning** | Resolve all claimants before replacement. Only proven aliases/representations coalesce; otherwise typed `IDENTITY_CONFLICT` preserves the confirmed row **and ownership**, marks partial/nonzero status, and withholds conflicted deletion authority. Incomplete discovery cannot prove a replacement safe. Independently complete, confirmed nonconflicting units may still update. The focused cases include same-scope duplicates, later-diverging copies and duplicate manifests within one tree. [P:99–103,166; R2:51–74] |
| **R2 finding 2 — open-reader SQLite rebuild cutover** | **Closed for planning** | Leases last until actual connection closure. Replacement holds writer coordination, blocks new opens, closes its own old handles, and drains other leases boundedly or returns `CACHE_BUSY` with the current cache intact. Stable coordination survives replacement and accepted aliases. Closed, coherent candidate/recovery generations and interruption handling explicitly prevent mixed-generation WAL/SHM. The planned tests target idle open readers, pending admissions, interruptions and WAL-backed states while retaining ordinary read/index concurrency. [P:113–119,168; R2:76–95] |
| **New identity-field mapping** | **Consistent; no new blocker** | Scoped `recordID`, optional `providerSessionID` and GUI `Session.id` have separate roles. Locator-based Codex/Claude keys do not bypass provider-ID claimant detection. OpenCode keys support qualified backend transitions; equal IDs alone do not prove equivalence. Database lookup uses the provider ID, and opaque record IDs are validated against normalized results. Output/reference and token contracts preserve these distinctions. [P:99–103,121,131–139,166] |

## Pinned-source confirmation

Codex constructs its app ID from the path and separately derives a provider-ID hint; Claude likewise separates its per-file ID from its session hint. OpenCode's legacy parsers use the provider ID, and its SQLite query binds the supplied session ID to `WHERE id = ?`. The new mapping therefore preserves existing app semantics while giving CLI references explicit meanings. Locator-readable histories without an upstream ID remain non-resumable; this does not promise database selection without a provider key. [M:`AgentSessions/Services/SessionIndexer.swift:2461–2478`; M:`AgentSessions/Services/ClaudeSessionParser.swift:145–166`; M:`AgentSessions/Services/OpenCodeSessionParser.swift:138–165,227–254`; M:`AgentSessions/OpenCode/OpenCodeSqliteReader.swift:1173–1185`; P:53,103,129]

The existing GUI upsert replaces metadata on an ID conflict, while its database connection lives beyond individual transactions and enables WAL. These are the relevant integration hazards; the plan explicitly specifies different CLI collision handling and connection-aware replacement. [M:`AgentSessions/Indexing/DB.swift:148–193,2174–2183`; P:101,113–119]

SQLite's official [corruption guidance, §§2.5–2.6](https://www.sqlite.org/howtocorrupt.html), [WAL lifecycle, §1.4](https://www.sqlite.org/walformat.html), and [connection-close API](https://www.sqlite.org/c3ref/close.html), checked **2026-10-23**, support the connection-lifetime and coherent-sidecar requirements. Actual closure includes outstanding SQLite resources; that detail is already covered by P:117, not an additional plan blocker. These are rolling documentation sources; the actual release SQLite/vendor version remains the qualification gate at P:163.

## Remaining findings and readiness boundary

**No remaining plan blocker or required amendment was found in this focused scope.** The other seven planning closures remain undisturbed. Package-access identity/wrappers and typed argv extraction are explicitly carried forward. [R2:97–111; P:97,139]

Concrete Codable definitions, the OS lock primitive, numeric resource tuning, release SQLite qualification, signatures, Intel execution and the planned acceptance tests remain implementation/qualification work. They are not claimed complete by this verdict. Owner approval is still required before implementation. [P:135,145–159,163–174]

No repository edits, tests/builds, coding grants, real private provider-history reads, implementation, publication or external messages were performed.

VERDICT: PLAN READY