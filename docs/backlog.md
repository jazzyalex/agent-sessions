# Backlog

Deferred, non-urgent work items. Each entry: what, where, why deferred, and the
decision if one was made. Newest on top.

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
