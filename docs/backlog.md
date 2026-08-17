# Backlog

Deferred, non-urgent work items. Each entry: what, where, why deferred, and the
decision if one was made. Newest on top.

## How to read this file

Every entry carries a stamp line directly under its heading:

```
  > **open** · sev: med · urg: low · verified 2026-08-14
```
(indented here only so this example does not show up in the index grep below.)

- **Status** — `open` (nothing shipped) · `partial` (some instances closed, the class is
  still live) · `done` (shipped — collapsed to a two-line tombstone) · `won't-do`.
- **sev** (severity) — what breaks while this stays unfixed:
  - `high` — wrong data shown, data loss, or a user-visible break with no workaround.
  - `med` — a feature is silently absent or degraded, or recovery needs a workaround the
    user would not guess.
  - `low` — cosmetic, latent/unwired, dead code, or a fixture/test gap.
- **urg** (urgency) — time pressure, which is *not* severity. A med-severity bug that a
  relaunch clears is low urgency; anything with a date attached (a contributor waiting, a
  vendor deprecation, a release) is high urgency even at low severity.
- **verified** — when the entry was last checked against the code. `—` means it has not
  been re-checked since it was filed. Entries rot: on 2026-08-14 two were found stale —
  one already fixed in full, one describing a bypass that had since landed. Re-verify
  before acting on an old date.

**Finding the hot ones.** There is deliberately no hand-maintained index here — that is the
same drift class the *Agent Source Plumbing* entry below is about. Derive it instead:

```bash
grep -n -B2 '^> \*\*\(open\|partial\|done\|won.t-do\)\*\*' docs/backlog.md
```

**Writing an entry.** Body fields, used as they apply: **What** · **Where** (file:line
links) · **Fix shape** · **Why deferred** · **Risk if wrong** · **To close**. Keep **Why
deferred** and **Risk if wrong** — they are what makes an old entry trustworthy months
later.

**Closing an entry.** Do not move it to another file. Collapse it to a two-line tombstone
(date, commit, test name) and delete the rest, or delete it outright when GitHub or the
CHANGELOG already records it. The `##` sections are areas of the codebase, not priorities.

---

## Cross-Surface Session Storage

### Audit and support distinct CLI, Desktop, IDE, and side-session stores
> **open** · sev: med · urg: low · verified —

- **Scope:** local session persistence only. Cloud sync, vendor backends, and remote
  account history are explicitly out of scope.
- **Why this exists:** sharing a CLI, SDK, or base event model does not prove that two
  product surfaces write the same local record. A surface can use a different root,
  companion database, sidecar metadata, event vocabulary, or retention path even when
  its primary transcript remains JSONL.
- **Confirmed Claude split:** standard transcripts are discovered under
  `~/.claude/projects`; Desktop Code metadata also lives under
  `~/Library/Application Support/Claude/claude-code-sessions`; Cowork/local-agent
  transcripts live in nested `.claude/projects` trees under
  `~/Library/Application Support/Claude/local-agent-mode-sessions`. The current reader
  already scans these roots, but coverage, joins, and duplicate handling have not been
  certified as one cross-surface contract.
- **Confirmed Codex split:** normal CLI, Desktop, IDE, and subagent rollouts share
  `~/.codex/sessions`, while side conversations are reconstructed from
  `~/.codex/sqlite/logs_*.sqlite`. `/side` is also available in current Codex CLI, but
  `CodexSideChatLogReader` currently labels every reconstructed side conversation as
  Codex Desktop.
- **Confirmed Cursor split:** the current Cursor reader covers
  `~/.cursor/projects/**/agent-transcripts/**/*.jsonl` and
  `~/.cursor/chats/**/store.db`. Cursor Desktop also has conversation/composer records
  in `~/Library/Application Support/Cursor/User/**/state.vscdb`; that artifact family is
  not currently discovered. Some modern Desktop agent windows may also write the
  `~/.cursor` stores, so the work must classify artifacts from controlled sessions
  rather than assign every path to one surface by assumption.

#### Investigation work
- Build a versioned storage matrix with one row per harness surface and columns for
  primary root, companion roots, physical format, stable session ID, surface marker,
  project/task identity, archive path, and retention behavior.
- Run paired, minimal local probes for CLI and Desktop using the same task. Record all
  files created or changed before interpreting their schemas. Include one ordinary
  session and one side/fork/subagent session where the surface supports it.
- For Codex, compare CLI `/side` with Desktop side conversations and determine whether
  both use the same log database records, whether either produces a rollout, and which
  structural field can identify the originating surface. Do not infer the surface from
  the location of the shared database.
- For Claude, test standard CLI, Desktop Code, and Cowork independently. Verify the
  transcript-to-sidecar join, missing-sidecar behavior, duplicate discovery across
  roots, surface-specific record types, and project/task attribution.
- For Cursor, identify which Desktop modes write `state.vscdb`, which write the
  `~/.cursor` JSONL/`store.db` pair, and whether IDs can join the two families. Document
  the `ItemTable` and `cursorDiskKV` records needed to reconstruct a conversation before
  adding a reader.

#### Parser work after the probes
- Remove the hard-coded Codex Desktop classification from reconstructed side sessions;
  derive a surface only from recorded evidence and use an explicit unknown value when
  the artifact does not identify it.
- Add Cursor Desktop discovery and parsing for the proven `state.vscdb` conversation
  families, with deterministic deduplication against any matching `~/.cursor` session.
- Harden Claude cross-root identity and deduplication so a transcript plus Desktop
  sidecar becomes one session, while Cowork sessions remain independently discoverable
  when the standard root is absent.
- Preserve artifact provenance on every parsed session: surface, primary artifact,
  companion artifacts, join key, and whether any expected component was missing.
- Keep all database access read-only and bounded; never depend on vendor UI state or a
  network/backend request to enumerate local history.

#### Acceptance evidence
- Commit sanitized fixtures for every physically distinct artifact family, including
  missing-companion and duplicate-ID cases.
- Add discovery tests proving that each supported root is found independently.
- Add parser tests for surface classification, stable joins, project/task attribution,
  side-session recovery, and deterministic deduplication.
- Add a local coverage report that lists discovered and unparsed artifact families so a
  new vendor storage path cannot silently disappear from the product.
- Re-run the same probes after vendor upgrades and record format drift per surface, not
  only per harness name.
- **Why deferred:** this needs controlled sessions and fixture sanitization before parser
  changes. Implementing from the current live databases alone would bake uncertain
  surface attribution into production code.

---

## Marketing Surfaces

### Session-Bench needs an in-app surface, and it is not a changelog entry
> **open** · sev: low · urg: low · verified —

- **Where:** currently only the public pages — `docs/bench/` and the launch post. Nothing
  in the app references it.
- **What:** Session-Bench is a separate research/accountability project, **not an Agent
  Sessions feature.** It was briefly listed under "Improvements" in the 4.8 changelog
  (the v0.3 poster); that framing was wrong and the entry was removed. Release notes
  describe what changed in the app, and the poster changed a website.
- **Decision:** surface it in-app as a **chip**, not as a release-note line and not as a
  feature panel row. Design it deliberately rather than bolting it onto the next release.
- **Why deferred:** wants its own design pass on placement and wording; there is no
  deadline pressure and shipping it inside a release note would repeat the category error.

---

## Agent Source Coverage

### Grok session sidecars are neither watched nor read
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** a Grok session is a directory, and beyond `chat_history.jsonl` +
  `summary.json` it also holds `rewind_points.jsonl`, `events.jsonl`, `updates.jsonl`,
  `prompt_context.json`, `resources_state.json`, `signals.json` and `system_prompt.txt`.
  No fixture covers any of them, the schema fingerprint ignores them, and no Swift reads
  them — so upstream could restructure any one without the weekly scan noticing.
  Surfaced 2026-08-17 from a kept prebump sandbox.
- **Where:** [GrokSessionParser.swift](../AgentSessions/Services/GrokSessionParser.swift)
  and [GrokSessionDiscovery.swift](../AgentSessions/Services/GrokSessionDiscovery.swift)
  read the transcript and `summary.json` only; the weekly `local_schema` glob is
  `*/*/chat_history.jsonl`.
- **Two separate jobs, do not conflate:** (a) *monitoring* — decide which sidecars are
  load-bearing and add them to the fingerprint or to `required_companion_files`, the way
  `summary.json` already is; (b) *product* — `rewind_points.jsonl` is the interesting one,
  since it records the session's rewind history and nothing in the app exposes that.
- **Related, still open from 2026-08-13:** `subagents/<childId>/meta.json` (the only place
  `parent_session_id` / `subagent_type` appear, so the hierarchy feature depends on it)
  and the `compaction/` subtree.
- **To close:** each sidecar is classified as watched, deliberately ignored, or a feature
  candidate — with the ruling written down so this is not re-derived a third time.

### Image extraction for Kimi, Pi, Hermes and Cursor is wired but inert
> **open** · sev: low · urg: low · verified 2026-08-14

- **Where:** the per-source gates in
  [CodexSessionImagePayload.swift](../AgentSessions/Utilities/CodexSessionImagePayload.swift)
  and [ImageBrowserIndexCache.swift](../AgentSessions/Utilities/ImageBrowserIndexCache.swift),
  shipped in `da428bf3`.
- **What:** those four providers were pointed at the generic
  `Base64ImageDataURLScanner` alongside Grok, but nothing confirms they ever emit an
  inline image. Verified 2026-08-14: **zero** occurrences of `data:image/` across every
  local session tree for them — `~/.kimi-code` (26 files), `~/.pi` (5), `~/.hermes`
  (2,973 + 3 SQLite), `~/.cursor` (255 incl. 20 `store.db`) — text and binary alike.
  Independently, they take the conservative `isLikelyImageURLContext` filter, whose regex
  requires an unescaped `"image_url":` immediately before `"data:image`; the real Grok
  payload uses a bare `"url"` key, so even a Grok-shaped URI would be filtered out for
  these four.
- **Why deferred:** additive and harmless while inert, and there is nothing to verify
  against without a real session. If one of them references images by path or https URL
  instead of a data URI, it needs its own reader — the generic scanner will never find it.
- **Note:** the 4.8 changelog says the scanner is *extended* to them, deliberately
  avoiding a promise that images appear. Keep that wording honest if this is revisited.

---

## Transcript UI

### MCP tool calls render anonymously though Codex now names the connector
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Codex `mcp_tool_call_end` events gained `app_name`, `connector_id`,
  `action_name` and `link_id` (found 2026-08-17 sweeping 1209 local sessions). Every MCP
  tool row in the transcript currently shows the raw tool name with no indication of
  which connector ran it, even though the record now says.
- **Where:** the Codex tool-event path in
  [SessionTranscriptBuilder.swift](../AgentSessions/Services/SessionTranscriptBuilder.swift);
  none of the four keys appear anywhere in `AgentSessions/`.
- **Fix shape:** surface `app_name` (or `connector_id` when the friendly name is absent)
  as a label or subtitle on MCP tool rows.
- **Risk if wrong:** the keys are new, so older sessions lack them — the label must be
  optional, never a layout requirement.
- **To close:** an MCP tool row shows its originating connector, and a fixture covers a
  record both with and without the keys.

### Qwen reports its context window size and nothing shows it
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Qwen assistant records carry `contextWindowSize`. There is no context-fullness
  indicator anywhere in the app, and this is the only source that states the window
  directly rather than requiring a per-model lookup table.
- **Where:** [QwenSessionParser.swift](../AgentSessions/Services/QwenSessionParser.swift);
  `contextWindowSize` appears nowhere in `AgentSessions/`.
- **Why deferred:** only useful next to a token count, so it naturally follows the Qwen
  usage entry under *Usage Tracking*. Do that one first.
- **To close:** context usage is displayable for at least one source without hardcoding
  per-model window sizes.

### Inline images lost their right-click menu everywhere
> **open** · sev: low · urg: low · verified 2026-08-13

- **Where:** the inline image row in the transcript —
  [InlineImageThumbnailGridView.swift](../AgentSessions/Views/InlineImageThumbnailGridView.swift)
  and its host [TranscriptBlockListView.swift](../AgentSessions/Views/TranscriptBlockListView.swift).
- **What:** inline image thumbnails no longer offer a right-click context menu in any
  provider's transcript. Click-to-open still works and is the preferred primary
  interaction, so this is about the secondary actions the menu carried (copy, reveal,
  open externally), not about changing how a plain click behaves.
- **Why deferred:** reported 2026-08-13 while verifying Grok inline images; explicitly
  deferred by the owner rather than fixed in that pass. Not caused by the Grok inline
  image work, which only widened the per-source gating in
  `SessionInlineImageMapper` / `refreshRichInlineImages` and touched no gesture or menu
  code — so the loss predates it and needs its own bisect.
- **Note:** any fix should keep click-to-open as the primary gesture; the menu is
  additive, not a replacement.

---

## Agent Source Plumbing

### Hand-maintained per-source lists drift every time an agent is added
> **done** 2026-08-16

Closed by the Session Source Registry program (Tasks 0-9, `main` at `760382ed`):
descriptors, `SessionSourceRegistry` and `SessionProviderCatalog` replaced the hand lists,
and the four silent `default:` holes named in SPEC §6.C (`resume(_:)`,
`Session.computeIsHousekeeping`, the two inner `ImageBrowserIndexCache` switches) became
exhaustive along with several others. Two hand-maintained lists
survive on purpose, both test-enforced: `SessionSourceRegistry.ordered` and
`PreferencesTab.sidebarAgentSources` (frozen sidebar order, so it cannot be registry-derived).
Spec: [2026-08-14-session-source-registry-SPEC.md](superpowers/plans/2026-08-14-session-source-registry-SPEC.md).
The remaining cost of a new source, and the PR #56 dry-run that measured it, are in
[adding-a-session-source.md](adding-a-session-source.md).
Tests: `testRegistryOrderEqualsSessionSourceAllCases`,
`testSidebarAgentSourcesAreEveryRegistrySourceExceptTheHiddenOnes`.

### Registry program follow-ups (final whole-branch review, 2026-08-16)
> **open** · sev: low · urg: low · verified 2026-08-16

- **What:** the six low-severity residues the program's final review triaged as
  follow-ups rather than must-fixes (0 must-fix / 6 follow-up / 18 accept-as-is):
  1. Guide-rot sentinel: [adding-a-session-source.md](adding-a-session-source.md) §6 is a
     hand snapshot; two review rounds each found omissions in it. Fix shape: a test that
     brace-matches exhaustive `SessionSource` switches in `AgentSessions/` against a
     pinned file list, failing when a new switch appears unlisted.
  2. Stale header comment: [SessionSourceRegistry.swift:21](../AgentSessions/Model/SessionSourceRegistry.swift:21)
     still says "THE one remaining hand-maintained per-source list" — `sidebarAgentSources`
     is a second (SPEC §6.A′.16 has the correct statement).
  3. Dead `?? same-key` double-read fallbacks at `PresenceEngine.swift:1564,1573,1595`
     (the fourth site died with Task 7's rewrite). Provably dead; delete.
  4. `AvailabilityContext.live()` (AgentEnablement.swift) has zero callers and is the
     UNCACHED detector — a hot-path adopter would reintroduce PATH sweeps. Delete or
     doc-fence it.
  5. `testAllowedSearchSourcesIsEnabledAndIncluded` needs a non-emptiness pin + one
     unconditional positive-membership assertion (two legs are tautological).
  6. `@AppStorage` enablement-default islands: `AnalyticsView`/`FirstRunSetupView`/
     `PreferencesView+General` keep literal defaults (hermes/cursor `true`, openclaw
     `false`) while their pi/kimi/grok rows use `AgentEnablement.isEnabled`; on upgrade
     installs with absent keys these three views can disagree with the (converged) main
     window. Mechanical: route all rows through `AgentEnablement`.
- **Why deferred:** none affects a fresh install or changes shipped behavior; the program's
  correctness bar was behavior preservation, and each of these is cleanup beyond it.
- **Risk if wrong:** low — worst case is the documented upgrade-cohort UI asymmetry (item 6)
  and doc rot (items 1-2); nothing corrupts data or search.
- **To close:** items 2-5 are one small mechanical PR; items 1 and 6 are each a short
  self-contained task.

### Three per-source behaviors the registry refactor deliberately preserved
> **open** · sev: low · urg: low · verified 2026-08-16

- **Where / what:** SPEC §8 items 6–8, each found during the refactor and left as-is so the
  program stayed behavior-preserving —
  - `UnifiedSessionIndexer.triggerRefresh` drops `mode` / `trigger` / `executionProfile`
    for OpenCode only (now inside that source's `ProviderHandle` wrapper,
    [OpenCodeSourceDescriptor.swift:88](../AgentSessions/OpenCode/OpenCodeSourceDescriptor.swift:88)).
  - Droid's Preferences pane is implemented and reachable but hidden from the sidebar
    (`PreferencesTab.sidebarHiddenSources = [.droid]`,
    [PreferencesView.swift:1232](../AgentSessions/Views/PreferencesView.swift:1232)).
  - `effectiveWorkingDirectoryURL(for:)` has no kimi/grok arm, so both fall to the generic
    `session.cwd` via its `default:`.
- **Why deferred:** each is an owner decision, not a defect — the refactor's whole
  correctness argument was bit-for-bit preservation, so changing any of them there would
  have been unreviewable.
- **Risk if wrong:** low — all three are the pre-refactor behaviors, unchanged; the risk is
  only that they stay unexamined (droid's finished pane stays invisible, OpenCode refresh
  triggers stay coarser than the other eleven) because nothing but this entry tracks them.
- **To close:** an owner ruling on each. Droid's is the only user-visible one.

---

## Kimi Code

### `turn.ended` carries per-turn duration that nothing reads
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Kimi's `turn.ended` wire event carries `durationMs` and `reason`, present in
  every session. The 2026-08-13 ledger entry already named this "the natural source of a
  per-turn duration UI" and it has sat unused since — filed here so it stops living as an
  aside in a ledger note.
- **Where:** [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift) —
  `turn.ended` falls through the `default:` branch to `.meta`, so both fields survive in
  `rawJSON` and are never read. `durationMs` appears nowhere in `AgentSessions/`.
- **Fix shape:** per-turn timing already has a home in
  [TranscriptTurnTiming.swift](../AgentSessions/Services/TranscriptTurnTiming.swift),
  which currently derives timing from timestamps; a source-reported duration is more
  accurate where it exists.
- **Risk if wrong:** only Kimi reports this, so any UI must degrade cleanly for the other
  eleven sources rather than showing a gap.
- **To close:** Kimi turns show a source-reported duration, or the field is explicitly
  declared redundant against derived timing.

### Fixture does not cover image / audio / video content parts
> **open** · sev: low · urg: low · verified —

- **Where:** `KimiSessionParser.textContent(from:)` —
  [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift), the
  `image_url` / `audio_url` / `video_url` arms that render `[image]` / `[audio]` /
  `[video]` placeholders. Fixtures:
  `Resources/Fixtures/stage0/agents/kimi/{small,assistant_tools,subagent_agent-0}.jsonl`.
- **What:** Kimi's `ContentPart` union is `text | think | image_url | audio_url |
  video_url` (kosong `message.ts`), but every checked-in capture contains only `text`
  and `think`. The three media branches are written and unexercised — the same shape of
  gap that hid the loop-event defect, where an unexercised branch looked correct for a
  week because no fixture reached it.
- **Why deferred:** needs a capture that actually attaches media. `ReadMediaFile` is in
  Kimi's tool list, so an image round-trip is reachable — it just was not part of the
  command set run on 2026-08-01.
- **Risk if wrong:** low severity, bounded blast radius. A mis-mapped media part
  degrades one event's text; it cannot break discovery, counting, or the other ten
  agents. Contrast with the loop-event defect, which silently emptied whole transcripts.
- **To close:** in a scratch dir, have Kimi read an image (e.g. `ReadMediaFile` on a PNG),
  capture the resulting journal, add it beside the existing fixtures, and assert the
  placeholder rendering plus `.meta`/`.assistant` classification.

### No `agent_watch` prebump driver for kimi
> **open** · sev: low · urg: low · verified —

- **Where:** `scripts/agent_watch_prebump_drivers.py` (`DRIVERS` registry);
  `docs/agent-support/agent-watch-config.json` → `agents.kimi` has `weekly` but no
  `prebump` block.
- **What:** Kimi is monitored only by the weekly `kimi_wire_newest` local-schema scan.
  Every scan therefore reports blocker `no_real_session_driver_configured`, and the
  verdict cannot rise above `supports_installed_only`.
- **Feasible:** yes — `kimi -p "<prompt>" --output-format text` is a real headless mode
  (verified at 0.29.1 and 0.31.1), so a `kimi_prompt` driver is buildable with a
  `home_override` sandbox on `KIMI_CODE_HOME` plus a `discover_session` contract of
  `sessions/**/agents/main/wire.jsonl`.
- **Why deferred:** a driver is a Python class in the shared registry with its own
  auth/sandbox handling, not a config line; it is its own task. Kimi currently sits in
  the same posture as Hermes and Cursor, which also run weekly-evidence-only.
- **Caveat worth keeping:** a green prebump would be necessary but not sufficient here.
  A `-p` one-shot never emits `turn.steer`, `plan_mode.*`, `permission.*`,
  `full_compaction.*` or a subagent journal, so the weekly real-session scan stays the
  primary drift signal either way (same finding as the 2026-07-17 Claude `mode` event).

---

## Codex Usage Meter

### Transient-failure cooldowns lock out both live sources with no reachable bypass
> **open** · sev: med · urg: low · verified 2026-08-14

- **What:** After a failed usage fetch, `CodexOAuthUsageFetcher` sets a 30-minute
  failure cooldown, and the CLI-RPC probe it falls through to sets a **60-minute**
  one. A single offline launch or network blip therefore locks out both authoritative
  sources — the RPC probe for a full hour — while the ~3-minute poll keeps being
  rejected by the gate.
- **Where:** the cooldown gates — **two** in the OAuth fetcher, one per API:
  [`fetchUsage`:126](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:126)
  and [`fetchUsageResult`:177](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:177)
  (the live polling path), sharing actor state; plus
  [CodexCLIRPCProbe.swift:47](../AgentSessions/CodexStatus/CodexCLIRPCProbe.swift:47);
  the fallthrough at
  [CodexStatusService.swift:2511](../AgentSessions/CodexStatus/CodexStatusService.swift:2511);
  `refreshNow` in `CodexStatusService.swift` and its only user-facing caller,
  [PreferencesView+Usage.swift:77](../AgentSessions/Views/Preferences/PreferencesView+Usage.swift:77).

#### Re-verified 2026-08-14 — the original entry was partly stale and partly understated
- **A bypass has since landed, but it does not cover this case.**
  `resetForUserRecheck()`
  ([:95](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:95))
  clears `lastFetchAt` / `lastFetchFailed` / `rateLimitedUntil`, reached via
  `recheckAuthNow`. But it sits behind `AuthRemediationBanner`, which only replaces
  the meter when the auth verdict is **alarming**. A transient network failure is not
  alarming, so the user gets `FooterRetryChip` instead — a spinning "Codex —
  reconnecting…" with **no Button and no gesture**
  ([CockpitFooterView.swift:390](../AgentSessions/Views/CockpitFooterView.swift:390)).
  The one control a user would actually reach for, Preferences → Usage → "Refresh
  now", routes through `refreshNow` straight into the gate.
- **The recovery path only half-clears.** `recheckAuthNow` calls
  `resetForUserRecheck()` on the OAuth fetcher but passes the RPC probe merely
  `cooldownSuccess: 0`
  ([:2145](../AgentSessions/CodexStatus/CodexStatusService.swift:2145)) —
  `lastProbeFailed` stays set, so the 60-minute *failure* cooldown still rejects it.
  `CodexCLIRPCProbe` has no `resetForUserRecheck` equivalent. The "authoritative
  recovery attempt" therefore cannot recover the source with the longer lockout.
- **The silent auto-recovery does not apply.** `shouldSilentlyRecheckAuth`
  ([:755](../AgentSessions/CodexStatus/CodexStatusService.swift:755)) fires only on
  `.unauthorized`, never on `.transient` — correctly, since retrying a dead network
  immediately is pointless.
- **Severity is lower than first written.** The JSONL fallback still runs (local
  `rate_limits` from `~/.codex/sessions`, no network, no cooldown, honestly labeled as
  a fallback source), so the meter usually still shows something and never shows a
  *wrong* number. All retry state is in-memory actor vars with no `UserDefaults`
  persistence in either file, so **quit-and-reopen clears it instantly**. This is
  recovery latency, not correctness: medium-low severity, low urgency.
  The earlier "largest remaining real defect in Codex cold-start behaviour" framing is
  retracted.
- **Fix shape:** give `CodexCLIRPCProbe` a `resetForUserRecheck()` and call it beside
  the OAuth one; make the retry chip's recovery action reachable during transient
  failures; have `refreshNow` carry a user-initiated flag that bypasses the failure
  gate. NWPathMonitor reset on network-path change is the nice-to-have on top.
- **Why deferred (2026-08-01, re-confirmed 2026-08-14):** the code change is small, but
  the **test burden is not** — that asymmetry is the whole reason this keeps sliding.
  Verification has to cover both cooldown clocks independently, the OAuth/RPC
  fallthrough order, the reachable-vs-alarming branch that decides which footer chip
  renders, and the interaction with the `.idle` promotion below (which shares this code
  path and should be fixed in the same change). Several states are only reachable by
  seeding retry state — `seedRetryStateForTesting`
  ([:103](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:103))
  exists for the OAuth half; the RPC probe has no equivalent yet, so the fix likely has
  to add one before it can be tested at all. Do not ship this as a one-line bypass
  without that suite.

### `.idle` can mislabel a cold-start transient failure
> **open** · sev: low · urg: low · verified —

- **What:** `CodexUsageModel.handleAuthFetchResult` promotes `.ok` → `.idle`
  ("No active Codex session") when a completed fetch returned nothing and nothing
  has ever been applied. `CodexUsageFetchResult.transient` covers offline, 5xx AND
  429 alike, so a cold launch during a rate-limit window reads "no active session"
  when the truth is "rate limited, retrying — no session needed".
- **Where:** `AgentSessions/CodexStatus/CodexStatusService.swift` (the promotion
  before `applyAuthState`), `QuotaData.codex(from:)` in
  `AgentSessions/Views/CockpitFooterView.swift:159-176` (passes neither
  `dataIsStale` nor `transientReason`, unlike `claude(from:)`).
- **Fix shape:** carry a reason on `.transient`, plus a latch — follow-up ticks
  return `.skippedCooldown`, which would otherwise flip the caption back — then make
  the promotion reason-aware. Best done together with the cooldown item above.
- **Why deferred (2026-08-01):** requires a three-way conjunction (cold launch AND
  no rollout from today/yesterday AND a transient first fetch), self-heals on the
  next success, and **no 429 has ever been observed on the Codex endpoint** (the
  documented 429 storms were Claude's edge). Also strictly better than the infinite
  "reconnecting…" spinner it replaced. Revisit only if a Codex-side 429 is actually
  seen.

### Two smaller findings from the same review
> **open** · sev: low · urg: low · verified —

- `.idle` does not reset `AuthStatusNotifier`'s one-shot episode where `.ok` did
  (`AgentSessions/Shared/AuthStatusNotifier.swift:43-46`), so a second genuine
  sign-out within one run could go unnotified.
- `UsageMenuBar` renders a moon glyph for Codex idle, but the dropdown's idle
  explainer is Claude-only (Codex rows go through `codexResetMenuTitle`), so the
  glyph has no explanation anywhere in the menu.

---

## Claude Cloud Sessions

### Reconsider the surface: presence badge instead of runway rows
> **open** · sev: low · urg: low · verified —

- **What:** Cloud sessions currently render as rows inside the Quota Meter's runway
  block, with the literal "Cloud" where a rate would be. **The owner questioned
  whether this belongs there at all, and the question is a good one.** Runway's
  grammar is rate-per-session — every row answers "how fast is this eating my
  budget?" A cloud row answers "unknown", takes a slot in a consumption-ranked list,
  and cannot be acted on (no reveal, no navigation, no resume).
- **Decisive argument:** cloud sessions bill the same account-level quota, so the
  Claude 5h/weekly figures **already include them**. Nothing is missing from the
  measurement. What is missing is only awareness — "something is running over
  there" — which is a presence signal, not a metering one.
- **Evidence it is the wrong container:** the friction during implementation
  (slot competition, an empty progress bar, a pseudo-rate label, three rounds of
  ordering corrections) is what happens when an object is put into a container whose
  language it cannot speak.
- **Proposed shape:** a compact indicator on the Claude provider row — e.g.
  `⛅ 2 cloud · 1 working` — outside the consumption ranking. Keeps the awareness
  value, frees the 4 detail slots for rows that carry real rates, removes the
  pseudo-rate and empty bar, and makes the ordering question disappear.
- **Cost to switch:** small. The endpoint, filter, catalog and live model all stand
  unchanged; only `appendingClaudeCloudRows` and the `RunwayAttributionConfidence
  .cloud` case (~80 lines) would be replaced.
- **Sizing input:** the account has 6 cloud sessions total and 0-2 live at any time,
  which argues for a low-weight affordance rather than rows.
- **Also unresolved if rows are kept:** the pinned window's hard 270pt cap
  (`limitsRowHeight × limitsMaximumRows`) has no scrolling, so a saturated panel
  clips silently; and with 4+ local sessions burning, cloud rows lose every detail
  slot and are not counted in the "+N sessions" summary either, so a live cloud
  session can go invisible on a busy day.
- **Why deferred (2026-08-01):** a design decision, deliberately not made at the end
  of a long session. Nothing shipped is stranded by it.

---

## Usage Tracking

### Qwen already reports its own token usage and we discard it
> **open** · sev: med · urg: low · verified 2026-08-17

- **What:** every Qwen transcript carries complete per-call token accounting that nothing
  reads. The records are `type: system` / `subtype: ui_telemetry`, and
  `systemPayload.uiEvent` holds `input_token_count`, `output_token_count`,
  `cached_content_token_count`, `thoughts_token_count`, `tool_token_count`,
  `total_token_count`, `duration_ms`, and `model`. Values are real and dense — one
  ordinary local session carries **53** such records (e.g. 18022 in / 362 out / 12125
  cached / 35 thinking, 11392 ms).
- **Where:** [QwenSessionParser.swift](../AgentSessions/Services/QwenSessionParser.swift)
  maps every `type: system` record straight to `.meta`, so telemetry is retained in
  `rawJSON` and never extracted. `usageMetadata` on assistant records is touched only to
  carry it across fragment merges — the numbers are never read out.
- **Why this is mis-filed today:** `agent-support-matrix.yml` lists "usage/rate-limit
  tracking" under Qwen's *unsupported surfaces*, which reads as "the data isn't there."
  The data is there; nobody opened it. Fix the matrix wording as part of this.
- **Fix shape:** extract the `uiEvent` counters into the existing usage/analytics path.
  Per-call `duration_ms` + tokens is also enough for a burn-rate view without a price
  table, which is strictly better evidence than estimating from a table that goes stale.
- **Risk if wrong:** double-counting. `usageMetadata` and `uiEvent` may describe the same
  call from two places; confirm which is authoritative on real records before summing.
- **To close:** Qwen sessions show token usage in Analytics, and the matrix no longer
  claims the surface is unavailable.

### Verify the Claude Web API usage source actually works
> **open** · sev: low · urg: low · verified —

- **What:** The Web API fallback (`claudeWebApiEnabled`; "Web API only" mode) is
  implemented — `ClaudeWebUsageClient.swift` + `ClaudeWebCookieResolver.swift`
  (reads the Safari claude.ai session cookie) — but has **never been observed
  serving data at runtime**. The source diagnostic has only ever shown OAuth;
  the CLI OAuth path recovers first and masks it.
- **How to prove:** set Claude Data source → "Web API only" (forces the path),
  reload, confirm the source flips to a web source and serves numbers, then
  restore Auto.
- **Caveats:** needs Safari signed into claude.ai; Full Disk Access is per-binary
  (the grant is on the production build, not the `.deriveddata-run` debug build) —
  so test from the production build, or grant FDA to the test binary.
- **Why deferred (2026-07-10):** owner skipped the live test; normal (OAuth) auth
  is fixed and sufficient for now.

---

## Transcript (Session view)

### Semantic filters (Plan / Code / Diff / Review) in the Session view
> **open** · sev: low · urg: low · verified —

- **First, validate demand — do NOT build on assumption.** The old Terminal view
  had semantic toggles alongside the role toggles; when Terminal was retired only
  the role filters (You/Agent/Tools/Errors) were restored (2026-07-06). Before
  porting semantic filters, confirm they're actually used/wanted — check whether
  anyone relied on "show only code / only diffs / only plans / only reviews", vs.
  role filters + ⌘F covering the real need. If demand is thin, close as WON'T-DO.
- **Where:** filter bar lives in
  [TranscriptPlainView.swift](../AgentSessions/Views/TranscriptPlainView.swift)
  (`sessionRoleFilterBar`); block filtering in
  [TranscriptBlockListView.swift](../AgentSessions/Views/TranscriptBlockListView.swift)
  (`TranscriptRoleFilter`, `applyingRoleFilter`, `matchesUnderActiveRoleFilter`).
  Terminal reference: `SessionTerminalView.swift` `SemanticKind` +
  `semanticFilteredLines` (per-LINE `line.semanticKind`).
- **Why deferred / why it's harder than roles:** roles map 1:1 to
  `LogicalBlock.Kind`, so filtering is a clean block-level predicate. Semantic
  kinds were computed **per line** in Terminal (a single assistant block mixes
  prose + code fences + diffs). Blocks carry no per-block semantic label, so this
  needs either (a) a new per-block semantic classification pass, or (b) sub-block
  (per-run) filtering — both materially larger and with more regression surface in
  the perf-sensitive windowed list. Est. 3–5× the role-filter work.
- **Decision (2026-07-06):** deferred; owner asked to backlog AND to verify need
  before committing to the port. Related: [[project_transcript_redesign_phase01_state]].

---

## QM / Runway

### Runway overflow "+X sessions" undercount (`withPendingRows`)
> **done** 2026-07-09

Shipped with the single-orphan promotion: `withPendingRows` now merges
`burnSummary.count + pendingIdentities.count`, burn summary keeping rate/deadline.
Test: `testRunwayPendingOverflowMergesWithBurnSummaryCount`.

### Runway "pause impact" projection is modeled but never displayed
> **open** · sev: low · urg: low · verified —

- **Where:** [CodexRunwayModel.swift](../AgentSessions/CodexStatus/CodexRunwayModel.swift) —
  `RunwayPauseImpactRow.deadline` / `.gainedSeconds`, the `RunwayDeadline` enum
  ([:11](../AgentSessions/CodexStatus/CodexRunwayModel.swift:11)), `deadline()`
  ([:512](../AgentSessions/CodexStatus/CodexRunwayModel.swift:512)), `gainedSeconds()`
  ([:521](../AgentSessions/CodexStatus/CodexRunwayModel.swift:521)),
  `minimumDisplayedGain`.
- **What:** The model computes, per session, "if you paused this, your quota would run
  out at X instead of Y — you'd gain N minutes" (`.afterReset` / `.runout(Date)` /
  `.noChange`). No view reads `.deadline` or `.gainedSeconds`; `runwayRow` renders only
  name + burn rate + load bar. The sole live consumer is the pressure-branch sort key
  `gainedSeconds` ([:447](../AgentSessions/CodexStatus/CodexRunwayModel.swift:447)); the
  values themselves are never shown.
- **Nature:** latent designed-but-unwired feature, **not a bug**. Cheap to leave.
- **Options:** (a) **surface** it — a small "→ reset" / "+Nm" badge in the row (answers
  "which session do I pause to survive to reset?"); (b) **trim** it — switch the sort to
  `normalizedRate` (already used by the after-reset branch) and delete
  deadline/gainedSeconds/`RunwayDeadline`/`minimumDisplayedGain`; (c) leave as-is.
- **Decision:** open — pending product call on whether the impact number is worth showing.

---

## QM / Runway (Claude)

### Claude runway rows intermittently show tokens/hour instead of weekly-share in Weekly mode
> **open** · sev: med · urg: low · verified 2026-08-16

- **Reported by owner (2026-08-16):** with the runway presentation set to Weekly, Claude
  session rows sometimes render raw token throughput instead of the weekly-average-burn
  share; Codex rows are correct in the same mode. **Update same day:** owner then observed
  Weekly mode showing the correct burn-rate for Claude too, with no code change in
  between — so this is **intermittent, not a permanent fallback.** That rules out "Claude's
  weekly data is structurally unmeasurable on this account" as the sole cause and points
  instead at something timing- or state-dependent: a stale/zero usage snapshot on first
  render before the weekly fetch lands, a refresh race between the 5h and weekly polls, or
  the `weeklyMeasurable` guard tripping only during a specific window (e.g. right after an
  app relaunch or a weekly-window rollover). Needs reproduction with logging, not a fix,
  before anything below is trusted as the actual cause.
- **Where:** the presentation resolves to `.tokensPerHour` instead of
  `.weeklyPercentPerHour` whenever `weeklyMeasurable` is false —
  [`effectivePresentation`](../AgentSessions/Views/AgentCockpitHUDView.swift:3152) (the
  `.weekly` case), fed by `weeklyRunout` computed via `RunwayBaselineMath.averageBurnRunout`
  in both [`request`](../AgentSessions/Views/AgentCockpitHUDView.swift:3223) (Codex) and
  [`claudeRequest`](../AgentSessions/Views/AgentCockpitHUDView.swift:3318). Same fallback
  also lives one layer down in
  [`CodexRunwayCalculator.weeklySnapshot`](../AgentSessions/CodexStatus/CodexRunwayModel.swift:947),
  which returns `nil` (→ token snapshot) whenever `remainingPercent <= 0` or the computed
  run-out yields `seconds <= 0`.
- **Not yet root-caused:** the call sites for Claude
  ([claudeRequest](../AgentSessions/Views/AgentCockpitHUDView.swift:3708)) and Codex
  ([codexRunwayRequest](../AgentSessions/Views/AgentCockpitHUDView.swift:3685)) look
  structurally identical, and `weekAllModelsRemainingPercent` /
  `weekAllModelsResetText` populate the same way Codex's week fields do
  (`ClaudeStatusService.swift:1261`, `ClaudeUsageModel.swift:530-535`). The divergence is
  therefore either in the *values* Claude's weekly usage source actually returns (e.g.
  `weekAllModelsRemainingPercent` reading 0% used / no run-out on this account) or in
  something not yet traced — a live snapshot comparison (Claude vs. Codex, same account,
  Weekly mode) is needed, not more static reading.
- **To close:** since it's intermittent, a single breakpoint won't catch it — add
  temporary logging of `claudeRunwayRequest`'s `resolved.rateUnit`,
  `weekRemainingPercent`/`weekResetText`, and `weeklyRunout` on every HUD refresh cycle,
  then correlate the tokens-mode ticks against app lifecycle (launch, wake, weekly-window
  rollover) and against `ClaudeUsageModel`'s fetch/refresh timing to catch it live.
- **Risk if wrong:** low blast radius — display-only, wrong unit label on a runway row,
  no data loss. Confusing enough to mislead pacing decisions, hence med severity.

---

## Resume / Terminal Launch

### `runAppleScript` blocks the main thread for the Terminal / iTerm path
> **open** · sev: low · urg: low · verified 2026-08-04

- **Where:** [AgentTerminalLauncher.swift:189](../AgentSessions/Resume/AgentTerminalLauncher.swift:189)
  (`process.waitForExit()`) → [BoundedProcessWait.swift:9](../AgentSessions/Utilities/BoundedProcessWait.swift:9).
- **What:** `waitForExit` is a busy-poll — `while isRunning { Thread.sleep(0.1) }` on the
  *calling* thread, up to a 10 s deadline, then SIGTERM + 0.5 s grace + SIGKILL +
  `waitUntilExit()`. `runAppleScript` is `private static` inside the `@MainActor enum
  AgentTerminalLauncher`, so it inherits `@MainActor` and every Terminal.app / iTerm2
  resume runs that poll on the main thread. Typical osascript round-trip is under a
  second, so it is invisible in normal use; the visible case is the **first-ever
  Automation consent prompt** for Terminal.app, where osascript sits waiting on the user
  and the UI is pinned for up to the full 10.5 s.
- **Verified 2026-08-04:** read both functions; the `@MainActor` inheritance and the
  `Thread.sleep` loop are both real. Confirmed **pre-existing** — untouched by the async
  launcher change, which only altered the Warp path.
- **Secondary hazard in the same function:** `standardOutput`/`standardError` are set to
  `Pipe()`s that are only drained *after* `waitForExit` returns (stderr) or never at all
  (stdout). An osascript that wrote more than the ~64 KB pipe buffer would block on write
  while we block on exit — a deadlock that only breaks when the 10 s timeout kills it.
  Not reachable with the current fixed scripts, which emit nothing; it becomes reachable
  the moment someone adds a script that prints.
- **Why it is newly cheap:** the `*TerminalLaunching` chain became `async throws` in
  `d4280354` (so the Warp cold start could be awaited and reported). The Terminal/iTerm
  wrappers are now `async` functions that happen to contain no suspension point, so
  hopping the osascript run off the main actor is a local change — no signature churn.
- **To close:** wrap the `Process` run in `await Task.detached { … }.value` the way
  `CodexResumeCoordinator` already does for CLI probes, and drain both pipes concurrently
  with the wait (or set them to `FileHandle.nullDevice` if the output is genuinely
  unwanted).
- **Risk if wrong:** low blast radius, and the failure mode is the current one — a stalled
  UI, not incorrect behavior. The one thing to preserve is that the throw still carries
  osascript's stderr, which is what surfaces "Terminal got an error…" to the user.

### Dead code: `CodexResumeSheet.launch(session:)`
> **open** · sev: low · urg: low · verified 2026-08-04

- **Where:** [CodexResumeSheet.swift:374](../AgentSessions/Resume/CodexResumeSheet.swift:374).
- **What:** A ~30-line `@MainActor private func launch(session:)` that switches over
  `settings.launchMode` and calls the four Codex launcher entry points. A project-wide
  search across the app and test targets finds **no callers**.
- **Verified 2026-08-04:** grepped `launch(session` across `AgentSessions/` and
  `AgentSessionsTests/`; the only hit is the declaration. Swift is statically dispatched
  here, so there is no dynamic-reference escape hatch.
- **Why it is still there:** it was carried through the `async throws` launcher change in
  `d4280354` (annotated in place) rather than deleted, to keep a commit about launcher
  signatures from also containing an unrelated deletion.
- **To close:** delete it, or re-wire it if the resume sheet is meant to have its own
  launch action distinct from `UnifiedSessionsView.resume(_:)`. Deleting it also strands
  two more methods — checked each one:
  - `CodexResumeLauncher.launchInWarp` / `.launchInWarpPreview` — **would become dead.**
    The sheet is their only caller; `CodexResumeCoordinator` reaches Warp through the
    static `AgentTerminalLauncher.launchInWarp` instead
    ([CodexResumeCoordinator.swift:77](../AgentSessions/Resume/CodexResumeCoordinator.swift:77)),
    not through the launcher instance. Delete all three together.
  - `CodexResumeLauncher.launchInITerm` — **survives.** Live caller at
    [CodexResumeCoordinator.swift:75](../AgentSessions/Resume/CodexResumeCoordinator.swift:75),
    on the real `quickLaunchInTerminal` path.
  - `CodexResumeLauncher.launchInTerminal` — **survives.** It is the
    `CodexTerminalLaunching` protocol requirement.
- **Risk if wrong:** none to runtime behavior; the only cost of getting it wrong is
  deleting a hook someone intended to wire up later.
