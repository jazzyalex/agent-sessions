# DeepSeek Harness session source — preparation

Status: **preparation only.** No Swift written, no `SessionSource` case, and no
pbxproj edit.

Target release: **5.2** (`versionIntroduced = "5.2"`), the release after 5.1
(Devin + fx). Owner decision 2026-08-30.

## Refresh status

This document was refreshed 2026-09-18 against the local checkout
`/Users/alexm/Repository/deepseek-harness` at `ddefc45fbc`.

The original document was verified against `dsh-v0.1.2-alpha.2` and is retained
as planning history only. The current writer is format **v3**. Muse performed a
read-only source audit; no `~/.dsh` contents, credentials, `.env` files, or
Agent Sessions source were read or changed.

Current authority:

- `packages/core/session/src/types.ts:66-88` — format-version contract and
  `SESSION_FORMAT_VERSION = 3`.
- `docs/session-format-status.md:21-35` — latest released version 3 and
  evidence tag `dsh-v0.1.5-alpha.1`.
- `docs/persistence-changes/historical-formats/README.md:31-34` — v0 through
  v3 history.
- `packages/session/session-format-catalog/src/generated.ts:14-18` — current
  catalog and adjacent migrations.

The installed global CLI is `dsh 0.1.5-rc.2`; do not treat that binary as the
source-of-truth for the checkout-backed implementation plan.

## 1. Why this source is worth the work

`deepseek-ai/deepseek-harness` has a large coding-agent audience and no Agent
Sessions session browser support yet. The original outreach context is
`https://github.com/deepseek-ai/deepseek-harness/discussions/4425`.

The implementation must be source-grounded and version-aware. A reader written
from the original PREP alone would silently misread current sessions.

## 2. Discovery and on-disk layout

### 2.1 Home and persistence root

- `packages/util/home-paths/src/index.ts:12,18,61,87-100,121` — explicit
  configured path wins, then non-blank `$DSH_HOME`, then `~/.dsh`.
- `packages/boot/app-boot/src/index.ts:216` — launcher root uses
  `resolveDshHome()`.
- `packages/session/session-persistence-jsonl/src/index.ts:96` — the backend
  requires a `root`; it does not itself default to `~/.dsh/sessions`.
- `packages/bundle/base/cordis.patch.yml:117-120` — the base composition sets
  the root to `dshHomePath('sessions')`.
- `packages/bundle/sdk-minimal/cordis.patch.yml:154-158` — SDK-minimal uses
  the same root but plaintext compression and a different row id.

Therefore `$DSH_HOME/sessions` is the normal composed root, not a universal
backend invariant.

### 2.2 Directories and generation files

- `packages/session/session-persistence-jsonl/README.md:59-72` — the layout is
  `<root>/<projectDir>/<encodedSessionId>/session.*`; no-cwd sessions use
  `_no-cwd/`.
- `packages/session/session-persistence-jsonl/src/format.ts:198-212` —
  `encodeSegment` handles `.`, `..`, `~`, unsafe characters, UTF-16 units, and
  lone surrogates. The old `~007E` description was only one special case.
- `format.ts:224-255` — `projectKey(cwd)` is lossy and `projectDir` selects
  `_no-cwd` when `cwd` is absent.
- `format.ts:266` — the encoded session id selects the session directory.
- `packages/session/session-format/src/filename.ts:5,14-17` — canonical names
  are `session.jsonl` for v0 and `session.vN.jsonl` for later generations.
- `packages/session/session-persistence-jsonl/src/format.ts:41-76` — `.zstd`
  and plaintext variants are selected by compression; current readers must
  expect `session.vN.jsonl[.zstd]` siblings.
- `index.ts:1394,1529-1541,1585-1591` — opposite encodings are an
  `encodingMismatch`, not a fallback.
- `index.ts:1518,1524,1554,1593` — legacy flat artifacts are rejected as
  `legacyLayout`.
- `index.ts:1368-1403` — the highest canonical generation is selected; a
  historical generation can be read before a successor is published.

The original relative `./.sessions` TUI-default claim was not found in the
current source. Treat it as a historical probe hint, not a discovery rule.

## 3. Header and event model

### 3.1 Header

Logical `SessionHeader` is defined in
`packages/core/session/src/types.ts:93-130`:

```text
version: 3
id: SessionId
createdAt: non-negative safe-integer Unix milliseconds
cwd?: absolute path
parentSession?: SessionId
isSeeded: boolean
origin?: "subagent"
delegationDepth?: number
agentPreset?: string
```

The physical first JSONL record is validated in
`packages/session/session-persistence-jsonl/src/format.ts:82-185`.
`delegationDepth` is required physically and defaults to zero only during
encoding. `seedLength`, `sandboxMode`, and `approvalPolicy` are not current
fields; stale forms are rejected or migrated.

The first JSONL record is in the first frame. It is not an external metadata
sidecar, although header-only reads avoid loading event rows.

### 3.2 Current v3 rows

- `packages/core/session/src/types.ts:470-493` — event envelope contains
  `type`, `seq`, `time`, `data`, and optional `ignorable`.
- `types.ts:417-468` — surface events and `sourceEventSeqs` contracts.
- `packages/session/session-persistence-jsonl/src/format.ts:306-323` — current
  serialization writes one physical JSON row per event.
- `packages/session/session-format-v1-to-v2/src/codec.ts:86-119` — sequence
  continuity remains a required invariant.

Current v3 does **not** use packed `text-chunks`, `reasoning-chunks`, or
`tool-call-chunks` rows. Those are historical v0/v1 forms handled by
`packages/session/session-format-v0-to-v1/src/codec.ts:23-33,203-294`.

Current assistant events use embedded streams:

- `packages/core/session/src/types.ts:321-335` — `assistant/message` and
  `assistant/attempt` carry stream records.
- `packages/session/session-persistence-jsonl/src/generation.ts:550-573` —
  stream replay and block assembly.

### 3.3 `sourceEventSeqs`

- `packages/core/session/src/seq-ranges.ts:18-67` — lossless range encoding,
  expansion, ordering, bounds, and safe-integer validation.
- `packages/session/session-format-v2-to-v3/src/payload.ts:265-312` — v3
  storage admission and surface provenance validation.

The original claim that the header remained at version 0 while this field was
new is obsolete. Version bumps and frozen codecs now signal v2/v3 semantics.

## 4. Zstandard frames, migration, and recovery

### 4.1 Concatenated frames

- `packages/session/session-persistence-jsonl/src/zstd.ts:1-6,48-104` — the
  file is a concatenation of independent Zstandard frames; scanning parses
  frame/block boundaries and checksums.
- `index.ts:1206-1227` — writes a header frame followed by batch frames.
- `index.ts:890-973` — reads each complete frame and detects torn tails.
- `zstd-public-decoder.ts:15-34` — per-frame public fallback decoder.

One-shot decompression is unsafe: it can return only the header. A Swift
reader must use structural frame scanning, not compressed-magic byte splitting.

### 4.2 Migrations

The supported chain is v0 → v1 → v2 → v3:

- `packages/session/session-format-catalog/src/generated.ts:14-18` — catalog.
- `packages/session/session-format-v0-to-v1/` — historical event and field
  normalization.
- `packages/session/session-format-v1-to-v2/` — packed-chunk folding,
  embedded streams, and seeded-cut changes.
- `packages/session/session-format-v2-to-v3/` — system heads, `ptc` naming,
  surface operation canonicalization, and validation changes.

The source generation is immutable. Read-only migration is in memory; writing
publishes a version-named successor beside the source without overwriting or
deleting the source. See `packages/session/session-persistence-jsonl/README.md:82`
and `packages/session/session-persistence-jsonl/src/index.ts:336-387,495-665`.

### 4.3 Recovery

Production persistence uses recoverable-prefix behavior while verification uses
strict validation:

- `packages/session/session-persistence-jsonl/src/index.ts:272-283` — runtime
  recovery/validation configuration.
- `packages/session/session-format/src/catalog.ts:139-157,231-251` — recovery
  and validation modes.
- `packages/session/session-persistence-jsonl/src/index.ts:730-740,836-844,889-965`
  — torn-tail handling and recovery.
- `packages/core/session/src/repair.ts:21-134` — crash repair and interrupted
  turn closure.

A third-party browser may expose a readable prefix, but must not present a
truncated prefix as complete. A committed `turn/end` remains a fatal semantic
boundary when its prior rows cannot be validated.

## 5. IDs, subagents, archive, and resume

- Session ids are opaque branded values; minting and collision rules are in
  `packages/core/session/src/index.ts:1003-1009`.
- Lineage uses `parentSession`, `origin: 'subagent'`, and durable
  `delegationDepth`; see `packages/subagent/subagent/src/depth.ts:28-35` and
  `child-agent.ts:42-51,139-156`.
- Forks create a new id and copy only a completed-turn prefix; see
  `packages/core/session/src/index.ts:1236-1312`.
- Archive ids live in the workspace domain global state, not beside the session
  log: `packages/workspace/workspace/src/spec.ts:46-75` and
  `packages/workspace/workspace/src/index.ts:226-290`.
- `unarchiveSession` exists; the original claim that there was no unarchive
  surface is stale.

Resume is surface-specific and there is no shipped `tui` profile:

| Surface | Mechanism | Important eligibility rule |
|---|---|---|
| Headless | `--session-id` | exact cwd; no-cwd, live, subagent, preset, and fork cases can be rejected |
| Web/API | adopt/observe then `agents.resume` | cwd must match; subagent-owned sessions are rejected |
| SDK | reuse the same session id | server creates/reuses session with cwd metadata |
| ACP | `session/resume` | same-directory cwd and active/subagent checks |
| Agent loop | `resumeSessionId` | write lease and interrupted-turn repair are applied |
| Fork | new id with completed-turn seed prefix | child inherits source cwd |

Relevant sources are `apps/cli/src/args.ts:4-16,144-152`,
`packages/bundle/headless/src/startup.ts:44-51`,
`packages/api/session-controller/src/agent.ts:272-274,421-476`,
`packages/acp/acp/src/index.ts:239-290`, and
`packages/core/agent-loop/src/index.ts:859-914`.

## 6. Surface and attachment boundaries

- Supported launch profiles are web, headless, sdk, sdk-minimal, and acp;
  `tui` is only an out-of-tree/custom-profile example.
- Desktop owns a reserved `$DSH_HOME/profiles/desktop` area and is not a CLI
  session profile; see `apps/desktop/README.md:5,36-69`.
- SDK and ACP are separate protocol surfaces, not alternate file formats.
- Web follow combines a gap-free event journal with live assistant-stream data;
  see `docs/architecture.md:109` and
  `packages/api/session-controller/src/history.ts:42-274`.
- Attachment bytes are outside the append-only log and referenced by content
  identity; image extraction is out of scope for the first Agent Sessions
  integration.

## 7. Proposed Agent Sessions scope for planning

These are planning inputs, not implementation approval:

1. Build a read-only DSH source descriptor, discovery/indexer, and parser that
   understands the composed `$DSH_HOME/sessions` root, `_no-cwd`, generation
   selection, encoding mismatch, and legacy-layout errors.
2. Read v3 directly and retain v0/v1/v2 compatibility through a bounded
   migration/normalization layer or an explicitly documented historical parser.
3. Decode concatenated Zstandard frames structurally, tolerate torn tails with
   an explicit incomplete state, and preserve sequence/turn semantics.
4. Map current embedded assistant streams, attempts, tool results, subagent
   lineage, seeded prefixes, archive state, and surface-specific resume
   eligibility into Agent Sessions’ existing model.
5. Add synthetic fixtures for each supported generation and corruption state;
   do not use private `~/.dsh` data as a fixture.
6. Keep image/attachment extraction and provider-specific live follow outside
   the first read-only history scope unless the implementation plan proves a
   minimal safe contract.

Required Agent Sessions integration obligations remain those listed in
`docs/adding-a-session-source.md`: source settings/environment/descriptor,
parser/discovery/indexer, resume surface, fixtures, registry and semantic
switch arms, target membership, and user-facing documentation.

## 8. Remaining evidence gaps

Before implementation, a planning session must distinguish source-confirmed
facts from steward-dependent evidence:

- real non-private directory shapes and cwd normalization examples;
- representative v0/v1/v2/v3 synthetic fixtures, including torn frames and
  migration boundaries;
- real subagent/fork/archive examples without inspecting private user sessions;
- exact archive storage discovery through the storage hub;
- whether Agent Sessions should offer read-only resume affordances per surface;
- whether search is supported by the configured persistence/query composition or
  must remain metadata browsing in v1.

Do not probe `~/.dsh`, credentials, or `.env` files to close these gaps. Use
source, published/synthetic fixtures, and an explicitly authorized steward.

## 9. Planning handoff

The separate planning-session prompt is
`docs/superpowers/plans/2026-09-18-dsh-source-implementation-plan-PROMPT.md`.
It asks a fresh session to re-verify this document against the current source,
resolve the remaining scope decisions, and write an implementation plan only.

No Swift implementation, branch, commit, push, or release claim is authorized
by this preparation document.
