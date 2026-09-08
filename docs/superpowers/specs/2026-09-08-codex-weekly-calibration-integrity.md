# Codex weekly Runway calibration integrity

Status: core correction implemented and validated 2026-09-08; the broader scoped-v2 evidence work remains in the parent backlog.
Verified against main at `9ad98b6886603969bf0404674ee1d67947a1b60c`, with existing Astra pricing edits, on 2026-09-08.
Implementation plan: [ordered implementation and validation](../plans/2026-09-08-codex-weekly-calibration-integrity.md).

## Problem and intended result

The owner saw 7.6%/h for a short Sol low-effort task and approximately 20%/h for a simple Astra task. The weekly rate must mean an estimated number of percentage points of the full weekly allowance consumed per hour if recent activity continues. It is neither the task's cumulative consumption nor a percentage of the remaining balance.

The formula remains `session API-equivalent dollars/hour × calibrated weekly percentage points/dollar` ([formula](../../../AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift:6), [application](../../../AgentSessions/CodexStatus/CodexRunwayModel.swift:1149)). The fix must ensure that calibration compares the same activity, account scope, time interval, and price snapshot. An incomplete or contradictory denominator must not produce a confident number.

## Evidence and limits of the diagnosis

These are observations from the preceding diagnosis, not frozen fixtures or current account balances:

| Observation | Evidence | Interpretation |
| --- | --- | --- |
| Historical scan: 4 reported points / $4.4226856 | `/tmp/agentsessions-wkcal.log`, 2026-09-08 19:41:50–19:41:53 UTC; 3 files, 70 matched records | Raw ratio 0.9044278436 pp/$; scan completeness is unproven. |
| Persisted live calibration: 2 points / 0.2269993272 pp/$ | `quotaMeter.weeklyCalibration.codex.*` in the local Agent Sessions preferences, acquired 19:36:46 UTC, interval 2514.4148 seconds | Implied denominator $8.8106 for a shorter interval in the same reported window. Event membership and live-ledger correctness require reconciliation. |
| Screenshot's Sol task has cumulative and per-request records plus explicit weekly anchors | Local rollout `01a08255-6f5a-7603-b7ce-881fd4e1f97e`, first turn 18:43:52–18:46:28 UTC, model `gpt-5.6-sol`, effort `low` | This task is not missing its weekly anchor. Its first turn ends at 524,669 input, 415,872 cached input and 3,556 output tokens. |
| Bootstrap and live used different accounting rules | Baseline `9ad98b6`: `WeeklyQuotaBootstrap.swift:300` summed `last_token_usage`; `CodexRunwayModel.swift:2978` differenced cumulative usage | Their equality was not guaranteed by construction. |
| Live ledger charged at poll time | Baseline `9ad98b6`: `WeeklyQuotaCalibration.swift:283` stored incremental dollars in `Bucket(at: now, ...)` | A newly discovered old event could be assigned to a later quota interval. |
| Bootstrap had no upper timestamp bound | Baseline `9ad98b6`: `WeeklyQuotaBootstrap.swift:299` checked only `timestamp >= windowStart` | A growing transcript could contribute events after the quota observation's cutoff. |
| Bootstrap could omit unreadable files and seed a model from later text | Baseline `9ad98b6`: `WeeklyQuotaBootstrap.swift:163,238` | A positive cost and zero unpriced share did not establish complete, correctly priced coverage. |

The dollar discrepancy is confirmed. Which side is wrong, and how much the screenshot was inflated, remain unproven until event-level reconciliation. Possible contributors are cumulative/per-request divergence, poll-time assignment, file discovery/archiving, duplicate ingestion, and scope filtering. Do not select the smaller ratio simply because it looks plausible.

Correction to the preceding answer: the 4.8%/h replay used the raw `3 / 9.5447104` ratio. Production bootstrap applies a `+0.5` quantization midpoint ([served ratio](../../../AgentSessions/CodexStatus/WeeklyQuotaBootstrap.swift:83)); the same isolated replay would be about 5.55%/h. Neither reproduces the in-memory selection at screenshot time. The quoted 4× ratio discrepancy is diagnostic evidence, not a proven correction multiplier.

## Scope

Repair Codex weekly calibration acquisition, ingestion, selection, persistence, and the weekly Runway consumer. Preserve the existing five-minute weighted activity window and 60-second evidence floor ([current algorithm](../../../AgentSessions/CodexStatus/CodexRunwayModel.swift:3063)). No change to quota polling, account balances, reset redemption, subscription sizing, or the meaning of the 5h, token and dollar modes. No feature flag or arbitrary rate clamp.

The existing [broader calibration backlog](../../backlog.md#weekly-quota-pricing-and-calibration-need-immutable-scoped-v2-evidence) remains the parent issue. This fix does not require redesigning every provider or publishing a new pricing manifest. Shared changes must preserve Claude behavior, especially source-provenance restrictions.

## Accounting contract

1. **One Codex normalization rule.** Historical and incremental ingestion must produce equivalent normalized usage events from the same bytes. Cumulative component counters are the accounting authority when present. Per-request usage may supply request context only when reconciled component by component with the delta. Never sum overlapping cumulative and incremental families. Existing [telemetry normalization](../../../AgentSessions/Telemetry/CodexTelemetryAccumulator.swift:66) is a reuse candidate; inspect and extend it rather than creating a third independent interpretation.
2. **Chronology and boundaries.** Resolve model and billing metadata only from applicable preceding structured records. Include the first request once when a complete transcript begins with known zero counters. For a partial tail without a baseline, do not invent the missing delta. Counter decreases, compacted/resumed segments, and multi-request cumulative jumps require explicit handling and coverage status. A multi-request delta must not be priced as one long-context request unless its boundaries are proven.
3. **Stable event identity.** Prefer provider request/event IDs. Where absent, use durable transcript identity plus record position and accounting segment, validated against file identity/content revision. Timestamp alone is insufficient. Duplicate discovery paths must not double count; two distinct events at the same timestamp must both count. Truncation/replacement invalidates affected cursors and evidence.
4. **Event time and observation time are distinct.** Charge activity to `(start, end]` using the event timestamp. Track poll heartbeats separately for freshness and discovery coverage. Late discovery recomputes or invalidates affected intervals; it must not charge historical work to the next quota tick. Bootstrap and live boundaries use the quota observation time, never scan completion time.
5. **Immutable pricing.** Capture one `RunwayPriceSnapshot` for the operation ([existing type](../../../AgentSessions/CodexStatus/RunwayPriceTable.swift:120)). Stamp its revision in normalized/priced evidence. A refresh during a scan must not mix rates or label an old denominator with a new revision. Preserve actual model, cache, request context, and known billing modifiers. Unknown material modifiers or unresolved request pricing make that interval unusable.
6. **Scope and coverage.** Evidence carries provider, account scope, source family, canonical root set, limit identity/duration, reset anchor, time bounds, pricing revision and accounting revision. A reset instant alone is not proof of account identity. Existing transcript anchors can constrain window membership; ambiguous account provenance must remain explicit and cannot be promoted to exact attribution. Preserve current fail-closed source rules.
7. **Bounded discovery.** Resolve the configured Codex roots; include supported archive locations when their membership is known, deduplicating moved transcripts. Unreadable candidates, scan limits, enumeration failures, malformed relevant records and unknown membership must be reported. A missing record is not equivalent to a zero-cost record. Full-week coverage cannot be established solely from currently present local files; deleted, remote or cloud usage may be absent.

## Calibration and selection contract

A candidate contains explicit numerator observations, priced interval cost, scope, coverage status and provenance. Full-week local bootstrap is only usable under its stated local-coverage assumption; it must not be labelled measured per-session quota or exact account coverage. Prefer bounded paired observations over assuming the entire weekly used percentage has a locally observable denominator.

For identical scope, price revision and interval, historical replay and incremental replay must produce the same event set and component totals, within floating-point tolerance for dollars. A claimed full-window denominator must be at least the cost of any proven contained interval. Failure rejects the affected candidate and exposes a diagnostic reason; it does not automatically bless the alternative candidate.

Selection first requires scope compatibility and adequate coverage, then applies conditioning/age rules. A larger numerator cannot make incomplete evidence win. If a valid compatible alternative exists, serve it with its provenance; otherwise use the existing measuring/unavailable behavior. Raw weekly remaining/reset information stays available independently.

Represent percentage precision explicitly. The current unconditional bootstrap midpoint is not a general precision model: exact values get no adjustment; rounded/floored values need the actual provider semantics. Until flooring is established, use conservative quantization bounds. For two whole-point endpoints, allow up to one point of uncertainty on their difference. Do not display a numeric rate from a candidate whose conservative lower bound is zero. Never infer weekly capacity from the plan's monthly dollar price.

The weekly row remains a recent-pace estimate. Add concise help text describing the five-minute window and extrapolation while keeping the compact value plain (for example `7.6%/h`, with no prefix). Keep detailed rejection reasons and calibration evidence in local diagnostics. No new network telemetry or account identifiers in diagnostics.

## Persistence and recovery

Introduce a Codex calibration evidence revision shared by live and bootstrap records. Reject old Codex records on every restore, migration, best-cache, and fallback path; the current live revision stamp does not cover bootstrap evidence ([live stamp](../../../AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift:516), [bootstrap compatibility](../../../AgentSessions/CodexStatus/WeeklyQuotaBootstrap.swift:58)). Do not invalidate Claude records merely because the Codex algorithm changes.

Canonicalize tolerated reset jitter for cache identity without merging genuinely different windows. Root changes, account/source changes, limit identity changes, price changes and accounting changes invalidate incompatible candidates. On restart, recover from retained valid evidence or recompute; never freshen a denominator over an unobserved gap. A scope change during an asynchronous scan must discard its completion.

## Acceptance criteria

- A frozen reproduction explains every dollar of the historical/live discrepancy by event inclusion, normalization, pricing or timing. Neither earlier ratio is an oracle.
- Cold bootstrap, incremental ingestion, restart replay and append replay agree for a common interval and scope. Duplicate polling, discovery order and batch size do not change totals.
- A late-discovered expensive event cannot inflate a subsequent interval; post-cutoff events cannot enter an earlier denominator.
- The first request, duplicate records, same-timestamp requests, model switches, counter resets, large tails and unknown pricing have explicit expected outcomes.
- The contained-interval inconsistency is rejected, including when its numerator is better conditioned than another candidate.
- Old Codex live and bootstrap caches cannot reappear through migration or fallback; valid Claude behavior remains covered.
- Identical standard-price Sol/Astra token components retain the currently configured 2.5× weighting. This checks relative arithmetic, not actual subscription capacity.
- A correct positive rate may still be high. Tests must establish accounting correctness rather than assert an appealing maximum.
- Builds and relevant tests pass; test-name/count changes are explained; a local replay validates the actual Swift path before shipping.

## Validation status

The core correction is implemented. Bootstrap now uses cumulative deltas, a fixed observation cutoff, chronological model attribution and one price snapshot; live ingestion uses stable event identity, event timestamps, the current weekly reset anchor and explicit scanner/poll coverage. Candidate selection rejects the demonstrated full-window-versus-contained-window contradiction, and Codex live/bootstrap evidence revision 6 prevents legacy denominators from resurfacing. The weekly UI marks numeric rates as estimates and explains the five-minute activity window.

Focused tests passed 239/239. The clean full XCResult contained 2,651 tests: 2,648 passed, 3 skipped and 0 failed. A standalone Debug build succeeded. The exact historical in-memory candidate set behind the screenshot cannot be reconstructed after the fact, so the regression freezes the contradiction and fails closed rather than asserting either historical denominator was correct. The fresh standalone app was launched at the user's request; visual UI automation was not performed, and live consumption from other clients remains unknowable from local transcripts.
