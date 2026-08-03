# Backlog

Deferred, non-urgent work items. Each entry: what, where, why deferred, and the
decision if one was made. Newest on top.

---

## Agent Source Plumbing

### Hand-maintained per-source lists drift every time an agent is added
- **Where:** the per-source sites that are *not* compiler-checked, all in
  [UnifiedSessionsView.swift](../AgentSessions/Views/UnifiedSessionsView.swift) unless
  noted —
  - `flashAgentEnablementNoticeIfNeeded()` — an 11-term `&&` chain over
    `<provider>AgentEnabled`
  - the `.onChange(of: <provider>AgentEnabled)` block that drives that notice
  - `enabledOtherAgentSpecs` — the filter-pill / overflow-menu spec array
  - `SearchCoordinator.start(...)` — one `include<Provider>: Bool` parameter per source,
    unpacked into an `allowed: Set<SessionSource>`
    ([SearchCoordinator.swift](../AgentSessions/Search/SearchCoordinator.swift))
  - the `@AppStorage(PreferencesKey.Agents.<provider>Enabled)` blocks duplicated across
    `UnifiedSessionsView`, `UnifiedSearchFiltersView`, `PreferencesView`, and
    `FirstRunSetupView`
- **What:** Kimi shipped as the 11th source in `47a50106` and was missed at four of
  these; Pi and the other late arrivals are missed at some of the same ones. The split is
  clean and predictable: **every site the compiler forces to be exhaustive was correct**
  (`switch` over `SessionSource`, `SessionSource.allCases` drivers such as the
  search-ingest kick and `AgentEnablement`), and **every hand-maintained list had
  drifted**. Nothing here is caught by a type error, and none of it is covered by tests,
  so each omission surfaces later as "provider X is invisible in feature Y".
- **Live instances still open** (found 2026-08-03, deliberately not bundled into the Kimi
  fix): the enablement notice is observed for only 6 of 11 agents — `hermes`, `droid`,
  `openClaw`, `cursor`, and `pi` have no `.onChange`, so disabling any of them alone still
  flashes nothing.
- **Closed 2026-08-03 (`747fcfaa`):** `enabledOtherAgentSpecs` now has its Kimi entry, with
  `shortcut: nil` like Hermes exactly as predicted above, so the pill, the overflow-menu
  item, and the `enabledAgentCount` contribution all exist. Two more instances of this same
  class turned up while fixing it and were closed with it: `PreferencesTab` had no `.kimi`
  case at all — leaving `KimiSessionsRootOverride` with three readers and no writer — and
  the has-commands quick filter's provider list omitted `.kimi`, so every Kimi session
  passed that filter with zero tool calls. That last one is now
  `UnifiedSessionIndexer.passesHasCommandsFilter`, an exhaustive `switch`, so it has left
  this drift class for good. The array and the notice chain below have not.
- **Direction:** make the shapes source-enumerated rather than hand-listed — derive the
  notice predicate and the pill specs from `SessionSource.allCases` filtered by
  `AgentEnablement.isEnabled`, and replace `start`'s parallel `Bool` parameters with the
  `Set<SessionSource>` it already builds internally. A single shared observable for
  enablement would also collapse the four duplicated `@AppStorage` blocks.
- **Why deferred:** it crosses view state, search, and preferences, and each has its own
  constraint — the pill array carries per-source colors and keyboard shortcuts, `start`'s
  signature is load-bearing for two test call sites, and the `@AppStorage` blocks feed
  SwiftUI invalidation, so collapsing them changes redraw behavior. That is a design pass,
  not a mechanical rename, and it should not ride along with a one-provider bug fix.
- **Risk if wrong:** medium blast radius, low severity per instance. A mistake here makes
  a provider silently absent from a filter or a notice — annoying and hard to notice,
  which is exactly the failure mode already observed, but it cannot corrupt data or break
  parsing.
- **To close:** convert at least the notice predicate and the pill specs to
  `SessionSource.allCases`, add the five missing `.onChange` observers (or delete them in
  favor of a derived value), and add one test that asserts every `SessionSource.allCases`
  member reaches the search allow-list — the drift class that
  `testSearchCoordinatorIncludeKimiGatesKimiSessions` only covers for Kimi. Kimi's own pill
  is done, but by hand, which is the point: the array is still hand-listed and the twelfth
  source will drift again.

---

## Kimi Code

### Fixture does not cover image / audio / video content parts
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

## Contributor PRs

### Check in on PR #51 / issue #53 — Claude Desktop live presence
- **What:** Follow up on the retarget left on PR #51. Lucas Jaeger (@Krazycatt,
  first-time contributor) built Claude Desktop chats into live presences by walking
  `~/.claude/projects` and classifying the transcript tail. The premise was stale —
  the Quota Meter already surfaces Desktop chats via
  `ClaudeRunwayRecentSessionScanner`, and the Cockpit HUD he targeted is deprecated
  — but it exposed a real bug, filed as #53. He was asked to keep the
  presence-synthesis skeleton and source the data from the runway identities
  instead of a second scan plus a second turn-state classifier.
- **Where:** [PR #51](https://github.com/jazzyalex/agent-sessions/pull/51),
  [issue #53](https://github.com/jazzyalex/agent-sessions/issues/53). The bug:
  `isSessionLive` means "a presence exists"
  (`AgentSessions/Views/UnifiedSessionsView.swift:3416`) and
  `supportsLiveSessionSource` includes `.claude`
  (`AgentSessions/Services/CodexActiveSessionsModel.swift:645`), so **Live sessions
  only** claims Claude yet hides every Desktop chat.
- **Check in ~2026-08-15:** if he is engaged, review the retarget. If quiet, close
  #51 with thanks, keep #53, and do it in-house — registering
  `ClaudeRunwaySnapshotLoader` identities as presences is close to the whole job.
- **Why deferred (2026-08-01):** waiting on the contributor on purpose. Growing the
  contributor base is worth more than the two weeks, and #53 is a correctness fix
  rather than an urgent one — severity is bounded by how much the **Live sessions
  only** toggle is actually used.

---

## Codex Usage Meter

### Codex OAuth failure cooldown has no user-initiated bypass
- **What:** After a failed usage fetch, `CodexOAuthUsageFetcher` sets a 30-minute
  failure cooldown. `refreshNow` goes through the same gate, so there is no way for
  the user to force a retry. Wi-Fi returning 20 seconds after an offline launch can
  leave the Codex meter dark for up to half an hour unless the CLI-RPC fallback
  happens to rescue it.
- **Where:** `AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift`
  (~:141-159, the cooldown gate), `refreshNow` in `CodexStatusService.swift`.
- **Fix shape:** bypass the failure cooldown for user-initiated refreshes, and
  ideally reset it on a network-path change (NWPathMonitor) so recovery is
  automatic rather than merely possible.
- **Why deferred (2026-08-01):** pre-existing, untouched by the 2026-08-01 meter
  work, and it deserves its own change with tests rather than an addendum to a long
  session. **This is the largest remaining real defect in Codex cold-start
  behaviour** — bigger than the snapshot persistence that was dropped in its favour.

### `.idle` can mislabel a cold-start transient failure
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
- `.idle` does not reset `AuthStatusNotifier`'s one-shot episode where `.ok` did
  (`AgentSessions/Shared/AuthStatusNotifier.swift:43-46`), so a second genuine
  sign-out within one run could go unnotified.
- `UsageMenuBar` renders a moon glyph for Codex idle, but the dropdown's idle
  explainer is Claude-only (Codex rows go through `codexResetMenuTitle`), so the
  glyph has no explanation anywhere in the menu.

---

## Claude Cloud Sessions

### Reconsider the surface: presence badge instead of runway rows
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

### Verify the Claude Web API usage source actually works
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
- **Where:** `RunwaySnapshotAssembly.withPendingRows` —
  [CodexRunwayModel.swift:344](../AgentSessions/CodexStatus/CodexRunwayModel.swift:344),
  `burstSummary: existing.burstSummary ?? pendingSummary`.
- **What:** When ≥ `maxRows` sessions are actively burning (so `snapshot()` already
  produced a full row set + a burn `burstSummary`) *and* extra active-but-not-burning
  sessions exist, those extras become `pendingIdentities`, get summarized, and are then
  discarded by `??`. The drawer's "+X sessions" counts only the hidden burns, silently
  omitting the idle actives — displayed count reads lower than the real concurrency.
- **Verified:** pure undercount, not a double-count (`burstSummary != nil` ⟹
  `rows.count == maxRows` ⟹ `openSlots == 0`, so no pending row overlaps the burns).
- **Fix:** merge the counts (`existing.burstSummary.count + hiddenPendingCount`),
  keeping the burn summary's rate/deadline (pending contributes 0 / `.unavailable`).
- **Decision (2026-07-03):** **Fold into the single-orphan Runway change**, not shipped
  standalone. Same function is rewritten there; needs its own test + a small
  rate-ownership decision. Low severity, rare trigger (≥ `maxRows` burning + ≥ 1 idle in
  one provider). Spec: [qm-runway-single-orphan-session-spec.md](qm-runway-single-orphan-session-spec.md) → Appendix A.
- **DONE (2026-07-09):** shipped with the single-orphan promotion — `withPendingRows`
  now merges `burnSummary.count + pendingIdentities.count` (burn summary keeps
  rate/deadline). Test: `testRunwayPendingOverflowMergesWithBurnSummaryCount`.

### Runway "pause impact" projection is modeled but never displayed
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
