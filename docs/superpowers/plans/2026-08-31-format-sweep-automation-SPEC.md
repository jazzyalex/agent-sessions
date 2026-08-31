# Format Sweep Automation — Spec

**Status:** ready for planning (amended 2026-08-31 after review)
**Date:** 2026-08-31
**Scope:** `scripts/agent_watch*.py`, `scripts/rebuild_stage0_baseline.py`, a new
`scripts/agent_format_tracker.py`, and `skills/agent-session-format-check/SKILL.md`.
One Swift file is read but **not modified** — see §10. Coordination in §12.

**Evidence base:** the 2026-08-31 sweep — five passes, nine version bumps, three
id-keyed-map traps caught, three of my own conclusions corrected, one near-miss data
loss. Every requirement below is traceable to something that actually happened that day,
and the numbers are cited so a reader can re-check them rather than take them on trust.

**Amendment note.** A review found ten defects in the first draft, all confirmed against
the code. Two were self-contradictions (§2's ordering was impossible; §10 banned the
Swift change §3.1 required), one was a TOCTOU in the fixture gate, and one would have
destroyed existing hand-written history. They are fixed below and called out where they
land, because the original errors are instructive.

---

## 1. The problem, stated honestly

The sweep works. It is not the sweep that is broken — it is that **the sweep's output
lives in a person's head until that person chooses to write it down.**

Today produced roughly forty distinct findings. All of them survived, but only because
each was manually transcribed into `docs/agent-json-tracking.md`, the ledger, or
`docs/backlog.md` at the end of each pass. Nothing enforced that. A session that ended
mid-pass — or an agent that ran out of context — would have lost everything discovered
since the last write, with no trace that it had ever been known.

Three secondary problems compound it:

| Problem | What it cost on 2026-08-31 |
|---|---|
| Auth failures surface one at a time, mid-run | grok, agy, pi and opencode each blocked a different pass, hours apart |
| The same class of finding is re-derived every sweep | `artifacts`, `modelUsage`, `promptCacheBreakState.models` — three instances of one trap, each investigated from scratch |
| Conclusions are recorded with the same confidence whether verified or assumed | "opencode: provider-side outage" was recorded as fact and was wrong |

**This spec does not ask for a smarter sweep. It asks for a sweep that cannot forget.**

## 2. Pipeline

Two weekly snapshots, not one. **This is amendment (7).** The first draft placed
conditional session generation before fingerprinting, which cannot work: the thinness and
staleness that decide whether to generate are computed *from* `schema_diff`, which only
exists after fingerprinting ([agent_watch.py:2831](../../../scripts/agent_watch.py:2831)).

```
1  batched auth preflight (§4)          ── one prompt, at minute zero
2  INITIAL weekly snapshot              ── fingerprint, verdicts, thinness, staleness
3  conditional prebump selection (§5)   ── decided FROM snapshot 1
4  one batched prebump for eligible agents
5  post-prebump installed-version reread   ── CLIs self-update; see §3.2
6  FINAL weekly snapshot
7  triage + proposal generation (§6)
      ↳ every finding appended to the tracker as it is made (§7)
   ─────────────────────────────────────────────────────────────
   GATE 1 — apply a reviewed fixture patch (§3.1)
   GATE 2 — apply a reviewed version claim (§3.2)
```

Steps 1–7 run unattended. The gates are **two confirmations per run**, against the dozens
the current workflow asks for.

**v1 does not install or update any CLI.** *Amendment (8).* The first draft implied
unattended installs with no adapter and no rollback policy. The sweep reports the exact
install command per agent and mutates nothing globally. CLIs that self-update as a side
effect of prebump are still handled — that is what step 5 exists for, and it is not
optional: on 2026-08-31 grok was already 1.0.13 before its loop began and pi moved
0.84.3 → 0.84.4 *between* two prebumps.

## 3. The two gates

### 3.1 Gate 1 — fixture patches

`rebuild_stage0_baseline.py --emit` appends redacted records to committed, public files.
`_redact` blanks string **values** but never dict **keys**, so a map keyed by an
identifier serialises real identifiers into a public artifact.

On 2026-08-31 this was one command away from happening three times:

| Agent | Map | Keyed by | Consequence if emitted |
|---|---|---|---|
| claude | `artifact-*-ledger.artifacts` | artifact UUID | every artifact any user creates reads as drift, forever |
| claude | `cost-state.modelUsage` | model slug (`claude-fable-5`) | every new model reads as drift |
| copilot | `promptCacheBreakState.models` | model id (`claude-haiku-4.5`) | same |

The first was caught **only** because a human asked to see the gap report before the emit.

**Requirement — split the tool in two.** *Amendment (4).* Reviewing a report and then
re-running `--emit` reviews one thing and applies another: the second run re-harvests
against a corpus that may have changed in between. Today's own corpus grew by two Codex
sessions mid-sweep. Refactor into:

- `build_plan()` — pure, produces an immutable **patch manifest**:
  - the exact redacted JSONL lines to append, verbatim
  - `fixture_base_sha256` of every target fixture
  - `source_manifest`: path + sha256 of every session harvested from
  - the uncovered (bucket, key) pairs the patch closes
  - `suspected_variable_key_maps`: every bucket whose key set differs across records
- `apply_plan()` — re-verifies `fixture_base_sha256` and `source_manifest`, runs the
  safety scan and `git apply --check`, and **refuses if any hash moved**.

Unattended mode may build a plan. It may never apply one.

**Requirement — variable-key detection at gate time is authoritative.** *Amendment (5).*
The first draft specified "a key appearing in fewer than N% of records" without defining
N, the denominator, the minimum sample, or the exceptions — a naive rule would reject
legitimate optional fields. The order of work is therefore:

1. Audit the current fixtures and record every bucket whose key set varies today.
2. Classify each as a genuine variable-key map or a fixed map with optional keys, and
   write the fixed ones into an explicit exception list with a reason each.
3. Only then pick a threshold, and require **zero unexplained failures** against the
   audited corpus before the rule is enforced.

Until that audit exists, the gate relies on the structural check — key set differs across
records of the same bucket — which needs no threshold and is what actually caught all
three maps today.

**Requirement — the widened guard is Python, and the Swift guard stays.** *Amendment (6).*
The first draft told the implementer to widen the existing guard while §10 forbade Swift
changes; the guard is Swift, at
[Stage0GoldenFixturesTests.swift:442](../../../AgentSessionsTests/Stage0GoldenFixturesTests.swift:442).
Resolution: the widened check (UUID **and** slug **and** path **and** header shapes) is
implemented in Python where the sweep can act on it, and the existing Swift UUID test is
left byte-for-byte unchanged as defence in depth. Document in both places that the Swift
test is the narrower of the two, so nobody reads a green Xcode run as full coverage —
it would not have caught `modelUsage` or `models`.

### 3.2 Gate 2 — version claims

`max_verified_version` asserts the app parses sessions *written by that build*. Two
failure modes showed up today: self-updating CLIs (above), and a verdict that reads as
evidence but is not — antigravity reported `rec=bump_verified_version` off a sample that
merely *matched*, with a failed prebump and 19 events at 0.308 coverage behind it.

**Requirement.** A proposal prints checkable assertions, not a verdict string:

```
antigravity  1.1.14 -> 1.1.22
  fresh_evidence_source        = latest_prebump_report
  latest_real_session_evidence = true
  blockers                     = []
  sample mtime 17:10:18Z  >  cli binary mtime 06:02:37Z   ✓ written by this build
  coverage 0.308  events 34    (thin gate: needs <25 events AND <50% coverage)
```

**Requirement.** Refuse to generate a proposal when any of these hold: the target is
upstream-only and not installed; prebump failed; evidence predates the **post-run** binary
mtime; schema unknowns or other blockers remain; or the installed version changed after
the proposal was generated.

**Requirement — the gate covers every write the claim implies.** *Amendment (9).* A bump
is not a YAML edit. Gate 2 applies **one exact patch spanning
`agent-support-matrix.yml` and `agent-support-ledger.yml`**, then appends tracker claim
events and regenerates the rendered section (§7). Proposal and application are **separate
tracker events**, so a crash between them is recoverable rather than ambiguous.

The ledger patch must be strictly additive. Today an insert replaced the previous entry's
`as_of_commit` line, merging two entries into one mapping with duplicate keys — and YAML
kept the last, so the file parsed cleanly while the new record vanished. The patch is
rejected unless the diff contains **zero deletions**.

## 4. Auth preflight

The only human input the sweep genuinely needs is authentication. Today it needed four,
discovered serially across several hours, each stopping a different pass.

**Requirement.** `--mode preflight` probes every agent's credential path **before any
other work** and emits one consolidated report:

```
auth preflight: 14 agents
  ready (10):  codex claude cursor kimi opencode copilot antigravity pi devin fx
  ACTION NEEDED (2):
    grok   — not signed in.  run: grok login --device-code
    qwen   — OAuth free tier discontinued 2026-04-15; needs a paid plan (not fixable here)
  warning (2):
    pi     — ~/.pi/agent/auth.json is 94 days old; may expire mid-run
    openclaw — config rejected by 2026.8.1 (tracker: openclaw/openclaw#133962)
```

**Requirement.** Per-agent preflight metadata is declared in
`docs/agent-support/agent-watch-config.json`, not hard-coded — the repo already carries
one hand-maintained per-source list too many.

**Requirement.** Report **credential presence** separately from **proven
authentication**. They are different facts, and conflating them is what produced today's
worst misdiagnosis: opencode's `credential_files` was empty, the sandbox therefore had no
credentials, and OpenCode's backend reported that as an opaque `UnknownError` that read
as a vendor outage for a full pass.

**Requirement.** Preflight generates no session, exposes no credential value, and
classifies each failure into the three §1c categories — *fixable ours*, *fixable theirs*,
*not fixable* — because only the first two are worth a prompt.

## 5. Session generation is conditional

`real_home_session` agents write their prebump session into the real store, where it
enters the newest-`_LOCAL_SCHEMA_SAMPLE_COUNT` window.

Measured today: antigravity has **31 transcripts, 29 of them under 10 lines**. Repeated
prebumps pushed its weekly union to **19 events at 0.308 coverage** and flipped it to
`blocked_thin_sample`. Its only two substantial transcripts (60 and 81 lines) are excluded
purely by age. One real user session restored it.

**Requirement.** Decided from the *initial* snapshot (§2), with explicit priority:

| Condition | Generate? |
|---|---|
| `real_home_session` **and** newest-5 union already below the thin gate | **no — refuses, and says running would make the verdict worse.** Highest priority: wins even over stale sample and newer version |
| Sample predates the installed CLI (`blocked_stale_sample`) | yes |
| A version bump is being proposed | yes |
| Already `supports_latest` and not stale | no — skip |

The first row is the opposite of what an eager automation does, and is the row that
matters.

## 6. Triage contract

The gap to close is not the taxonomy — it is that **the funnel keeps answering "does it
still parse?" when the question that matters is "did upstream start telling us something
we should show?"** Two of today's most valuable findings were invisible to a parse check:
Claude cache writes billed at the 5-minute rate when 100% of 182.9M local cache-creation
tokens are 1-hour (the `$` view understated by **16.6%** — a wrong *rate* parses
perfectly), and Claude's new `cost-state.totalCostUSD`, the session's *measured* cost.

| Bucket | Meaning | Automatic action |
|---|---|---|
| **urgent** | wrong data shown, data loss, or discovery broken | read-only subagent returns a patch + evidence (§8); never auto-applied |
| **support now** | upstream ships information a user would want and we drop it | implementation prompt + one-paragraph user-impact rationale, for you to accept or decline |
| **backlog** | real but not actionable yet | a **backlog patch proposal**, not a direct write — see below |
| **log only** | plumbing, ids, telemetry | tracker event only, so it is never re-litigated |

**Requirement — backlog writes are proposals and must be idempotent.** *Amendment (10).*
`docs/backlog.md` has structured status/severity/urgency/verified conventions
([backlog.md:6](../../backlog.md:6)) and a re-run must not file the same finding twice.
Each generated entry carries a stable marker derived from `finding_id`; generation skips
any finding whose marker is already present. **Accepting a backlog entry is post-sweep
product triage and is explicitly not one of the two sweep gates** — otherwise every
run acquires a third confirmation.

**Requirement — triage consumes values, not names.** It reads actual field values, parser
behaviour, the frequency measurement (§7), and release-note hints. A bucket is never
assigned from a field name: my `SubAgentActivity` count was a substring grep, wrong by
~20× (1561 lines claimed, 78 actual), and it drove an "urgent" framing that a real count
demoted to minor.

**Requirement — frequency is measured before promotion.** `cost-state` is 1 record in 1
of 80 sessions; copilot's `reasoningBlocks` is 2 records in 13 sessions. The `budget_usd`
precedent (2 of 410) is why: a field that looks transformative may occur almost never.

## 7. The tracker

**Requirement — a finding is a stream of events, not a row.** *Amendment (1).* The first
draft required a `bucket` on the record appended at discovery, while §6 requires a
corpus-wide frequency that is not known until later. That is a contradiction. Findings
are identified by a stable `finding_id`; events append under it:

| Event | When | Carries |
|---|---|---|
| `discovered` | the instant a new type/key is confirmed, mid-scan | field, first observation, evidence, `confidence` |
| `triaged` | after frequency measurement | `bucket`, frequency, rationale |
| `corrected` | any time | `supersedes`, what changed and why |
| `action_applied` | after a gate | what was written, patch hash |

**Requirement — `record_id` and `finding_id`, not timestamps.** *Amendment (2).* The
first draft had `supersedes` reference a second-resolution `ts`, which is not unique.
Every record carries a UUID `record_id`; `supersedes` references a `record_id`. `ts` is
microsecond UTC and is for humans and ordering, never identity.

**Requirement — JSONL, appended durably.** Locked `O_APPEND` write, flush, `fsync`; the
call returns only once the record is durable. Format is JSONL rather than YAML precisely
because of today's duplicate-key loss: an append-only JSONL log cannot merge two records.

```json
{
  "schema_version": 1,
  "record_id": "0198f3c2-6b41-7a10-9c3e-2f7d5a1e4b88",
  "finding_id": "copilot/session.usage_checkpoint.data.promptCacheBreakState.models",
  "event": "triaged",
  "ts": "2026-08-31T17:27:53.412887Z",
  "run_id": "20260831-172753Z",
  "agent": "copilot",
  "bucket": "urgent",
  "confidence": "verified",
  "observation": "dict keyed by model id; observed key claude-haiku-4.5",
  "frequency": {"records": 1, "sessions": 1, "of_sessions": 13},
  "evidence": ["scripts/probe_scan_output/agent_watch/20260831-172753Z-prebump/report.json"],
  "supersedes": null
}
```

**Requirement — `confidence` is mandatory**, with exactly two values: `verified` (a
command ran and its output is in `evidence`) or `assumed`. Today "opencode: vendor
outage" was recorded with the same authority as measured fact and was wrong; stamped
`assumed`, the next pass would have re-tested rather than trusted it.

**Requirement — existing history is frozen, not migrated.** *Amendment (3).*
`docs/agent-json-tracking.md` already holds extensive heterogeneous hand-written history
that cannot be reconstructed from a tracker that did not exist when it happened. The
first draft's "becomes a rendered view" would have destroyed it. Instead: everything
before 2026-09-01 stays **byte-for-byte frozen** as legacy history, and the renderer
writes only inside fixed generated-section markers below it.
`agent_format_tracker.py render --check` fails when the committed view is stale, so the
rendered section cannot drift from the log.

## 8. Subagents propose, one verifier applies

Subagents were the strongest part of today's run — three ran in parallel, and one
contradicted my own wrong number, which is precisely the value. An autonomous fixer is
how the UUID leak ships.

**Requirement.** Subagents are read-only: they return patch text and evidence, write
nothing to the repo, and never run `xcodebuild` — the existing repo rule that parallel
edit-agents must not build.

**Requirement.** One serialized verifier applies accepted patches and runs the suite once.
Test count is an invariant read from the `.xcresult` bundle, never stdout, and must not
decrease.

## 9. Acceptance tests

1. **Tracker survives a kill.** `SIGKILL` after an acknowledged `discovered` append —
   the record is present and the file is valid JSONL.
2. **Concurrent appends** do not merge or truncate records.
3. **Legacy history preserved.** The renderer leaves all pre-2026-09-01 content
   byte-for-byte identical; `render --check` fails on a stale committed view.
4. **Gate 1 refuses moved hashes.** Build a plan, modify a source session, apply — the
   apply is rejected on `source_manifest` mismatch.
5. **Gate 1 catches all four key shapes.** Fixtures containing UUID-, model-slug-,
   path- and header-keyed maps each fail the Python guard. (Today's Swift guard catches
   only the first.)
6. **Gate 2 refuses.** An agent with a failed prebump, and separately one whose target is
   upstream-only, each produce no proposal.
7. **Ledger patch is additive.** A patch containing any deletion is rejected.
8. **Preflight batches.** Two unauthenticated agents appear in one report, before any
   agent work begins, with no session generated and no credential value printed.
9. **Thin-store refusal.** A `real_home_session` agent below the thin gate never invokes
   a driver, even when its sample is stale and a newer version exists.
10. **Correction chain.** A `corrected` event referencing a `record_id` renders the
    correction while preserving the original.
11. **Idempotent re-run.** Re-running the same `run_id` produces no duplicate findings
    and no duplicate backlog entries.

Run: `pytest -q scripts/tests`. **No Xcode build is required** for this Python/docs work.
A separately accepted Swift fix uses `./scripts/xcode_test_stable.sh`, reads the total
from the `.xcresult`, and then runs the Debug build.

## 10. Out of scope

- **Modifying any Swift file.** The existing Swift UUID guard is read and referenced but
  left unchanged (§3.1). Product fixes arising from triage are separate work.
- **Installing or updating agent CLIs** (§2). v1 reports the command and mutates nothing.
- **Replacing `agent-support-ledger.yml`.** It stays the release-verified record; the
  tracker is the finding log. They answer different questions.
- **Automating `steward_check.py`.** Steward-owned agents follow §1g — ping, do not chase.
- **Auto-installing beta builds to work around upstream bugs.** openclaw's fix rides
  `2026.9.1-beta.1`; installing it unasked is not the sweep's call.

## 11. Honest limitations

- **This makes the sweep unforgetful, not correct.** Three of today's conclusions were
  wrong on first pass. `confidence` and the `supersedes` chain are the mitigation, not a
  cure.
- **Two gates is not zero.** The request was "as few asks as possible". Two per run is
  the floor I can defend; §3 is the argument. If they are removed anyway, do it knowingly.
- **The thin-sample weakness is untouched.** antigravity clears today because one real
  session exists; it will fail again the next time five thin sessions lead the window.
  Filed separately in `docs/backlog.md` and deliberately not folded in here.
- **Upstream release-note parsing will be unreliable.** Vendors do not publish schema
  changes. Codex 0.151's subagent-identity move appeared in no release note; it was found
  by counting fields. Treat the online channel as a hint, never as evidence.
- **The shared corpus layer is the largest risk in the build.** Frequency measurement
  requires one enumeration path across JSONL, SQLite and bespoke stores; today
  `_all_sessions` reads only `roots`/`glob` and never `db_roots`, which is already filed
  at [backlog.md:578](../../backlog.md:578). Getting this wrong silently mis-measures
  every frequency the triage depends on.

## 12. Coordination

A parallel session owns Qwen work (`2026-08-31-qwen-0.22-format-brief.md`) and recently
landed runway pricing (`c1dcb058`) and the CI test job (`5e4e59c7`). This spec touches
neither Swift nor CI. If it grows to, coordinate first — today two sessions building the
same project concurrently corrupted a module cache and produced two runs that reported
failures having executed zero tests.
