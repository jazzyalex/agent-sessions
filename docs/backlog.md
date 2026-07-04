# Backlog

Deferred, non-urgent work items. Each entry: what, where, why deferred, and the
decision if one was made. Newest on top.

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
