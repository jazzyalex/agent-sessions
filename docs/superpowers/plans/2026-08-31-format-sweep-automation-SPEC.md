# Format Sweep Automation — Spec

**Status:** ready for planning
**Date:** 2026-08-31
**Scope:** `scripts/agent_watch*.py`, `scripts/rebuild_stage0_baseline.py`, a new
`scripts/agent_format_tracker.py`, and `skills/agent-session-format-check/SKILL.md`.
No Swift. See §11 before touching anything.

**Evidence base:** the 2026-08-31 sweep — five passes, nine version bumps, three
id-keyed-map traps caught, three of my own conclusions corrected, one near-miss data
loss. Every requirement below is traceable to something that actually happened that day,
and the numbers are cited so a reader can re-check them rather than take them on trust.

---

## 1. The problem, stated honestly

The sweep works. It is not the sweep that is broken — it is that **the sweep's output
lives in a person's head until that person chooses to write it down.**

Today produced roughly forty distinct findings. All of them survived, but only because
each was manually transcribed into `docs/agent-json-tracking.md`, the ledger, or
`docs/backlog.md` at the end of each pass. Nothing enforced that. A session that ended
mid-pass — or an agent that ran out of context — would have lost everything discovered
since the last write, and there would be no trace that it had ever been known.

Three secondary problems compound it:

| Problem | What it cost on 2026-08-31 |
|---|---|
| Auth failures surface one at a time, mid-run | grok, agy, pi and opencode each blocked a different pass, hours apart |
| The same class of finding is re-derived every sweep | `artifacts`, `modelUsage`, `promptCacheBreakState.models` — three instances of one trap, each investigated from scratch |
| Conclusions are recorded with the same confidence whether verified or assumed | "opencode: provider-side outage" was recorded as fact and was wrong |

**This spec does not ask for a smarter sweep. It asks for a sweep that cannot forget.**

## 2. What becomes automatic, and what does not

The pipeline runs unattended from end to end **except two gates**. Everything up to and
including a *proposal* is automatic. The two actions that write something we cannot
easily take back stay gated.

```
preflight auth (§4)                     ── one prompt, batched, at minute zero
  ↓
per agent, unattended:
  detect installed / upstream version
  generate sample session, conditionally (§5)
  fingerprint + gap report
  fetch upstream release notes / changelog
  triage each new field (§6)
  APPEND every finding to the tracker (§7)   ← happens at discovery, not at the end
  ↓
GATE 1 — write to committed fixtures (§3.1)
  ↓
GATE 2 — claim a verified version (§3.2)
  ↓
propose fixes via subagents (§8)
```

The gates are cheap: **two confirmations per run**, not the dozens the current workflow
asks for. Everything else — installs, prebumps, fingerprinting, upstream lookups, triage
drafting, tracker writes — needs no human.

## 3. The two gates, and why they survive

### 3.1 Gate 1 — writing to committed fixtures

`rebuild_stage0_baseline.py --emit` appends redacted records to files that are committed
and public. `_redact` blanks string **values** but never dict **keys**, so a map keyed by
an identifier serialises real identifiers into a public artifact.

On 2026-08-31 this was one command away from happening three times:

| Agent | Map | Keyed by | Consequence if emitted |
|---|---|---|---|
| claude | `artifact-*-ledger.artifacts` | artifact UUID | every artifact any user creates reads as drift, forever |
| claude | `cost-state.modelUsage` | model slug (`claude-fable-5`) | every new model reads as drift |
| copilot | `promptCacheBreakState.models` | model id (`claude-haiku-4.5`) | same |

The first was caught **only** because a human asked to see the gap report before the
emit. A fully unattended pipeline would have shipped it.

**Requirement.** `--emit` never runs unattended. The run stops, prints the gap report,
and names every bucket whose key set differs across records — the machine-checkable
signature of a free-form map — with a recommendation to opaque-list or proceed.

**Requirement.** The existing guard test only matches UUID-shaped keys, so it would not
have caught `modelUsage` or `models`. Widen it: a committed fixture must contain no dict
key that (a) matches a UUID, **or** (b) appears as a key in fewer than N% of records of
that bucket type — the shape test, not the format test.

### 3.2 Gate 2 — claiming a verified version

`max_verified_version` asserts the app parses sessions *written by that build*. Nothing
mechanical can confirm the claim is honest, and two failure modes showed up today:

- **Self-updating CLIs.** grok was already 1.0.13 before its loop began; pi went
  0.84.3 → 0.84.4 *between* two prebumps. A bump written from the version observed at
  run start would have been wrong both times.
- **A verdict that reads as evidence but is not.** antigravity reported
  `rec=bump_verified_version` off a sample that merely *matched* — with a failed prebump
  and 19 events at 0.308 coverage behind it.

**Requirement.** A bump proposal must print its evidence as assertions the human can
check in one screen, not a verdict string:

```
antigravity  1.1.14 -> 1.1.22
  fresh_evidence_source      = latest_prebump_report
  latest_real_session_evidence = true
  blockers                   = []
  sample mtime 17:10:18Z  >  cli binary mtime 06:02:37Z   ✓ written by this build
  coverage 0.308  events 34   (thin gate: needs <25 events AND <50% coverage)
```

**Requirement.** The proposal states which of `installed` / `upstream` it is claiming and
refuses to offer a version that is merely *available*. Today pi was correctly bumped to
the installed 0.84.4 and not the upstream-only 0.84.4-successor; that discipline must be
enforced, not remembered.

## 4. Auth preflight — batch the interruptions

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
    openclaw — config rejected by 2026.8.1 (see tracker: openclaw/openclaw#133962)
```

**Requirement.** Preflight must distinguish the three §1c categories — *fixable ours*,
*fixable theirs*, *not fixable* — because they need different responses and only the
first two are worth a prompt. opencode's failure looked like a vendor outage for a full
pass; it was an empty `credential_files` on our side. Preflight tests the credential path
directly rather than inferring it from a driver failure.

## 5. Sample generation is conditional, not universal

"Generate a sample session for every agent every run" would actively damage the
monitoring. `real_home_session` agents write their prebump session into the real store,
where it enters the newest-`_LOCAL_SCHEMA_SAMPLE_COUNT` window.

Measured today: antigravity has **31 transcripts, 29 of them under 10 lines**. Repeated
prebumps pushed its weekly union to **19 events at 0.308 coverage** and flipped it to
`blocked_thin_sample`. Its only two substantial transcripts (60 and 81 lines) are
excluded purely by age. One real user session restored it.

**Requirement.** Generate a session only when it would change the answer:

| Condition | Generate? |
|---|---|
| Sample predates the installed CLI (`blocked_stale_sample`) | yes |
| A version bump is being proposed | yes |
| Verdict is already `supports_latest` and not stale | no |
| Agent is `real_home_session` **and** its store's newest-5 union is already thin | no — refuse, and say that running would make the verdict worse |

The last row is the important one and is the opposite of what an eager automation does.

## 6. Triage contract

The four buckets map onto §1e's existing three plus severity. The gap to close is not the
taxonomy — it is that **the funnel keeps answering "does it still parse?" when the
question that matters is "did upstream start telling us something we should show?"**

Two of the most valuable findings today were invisible to a parse-safety check:

- Claude cache writes billed at the 5-minute rate when 100% of 182.9M local
  cache-creation tokens are 1-hour — the `$` view understated by **16.6%**. A wrong
  *rate* parses perfectly.
- Claude's new `cost-state.totalCostUSD` — the session's *measured* cost, ground truth
  for the number the runway estimates.

**Requirement.** Every new key or type is assigned exactly one bucket, and the assignment
is written to the tracker with its evidence:

| Bucket | Meaning | Automatic action |
|---|---|---|
| **urgent** | wrong data shown, data loss, or discovery broken | subagent proposes a fix (§8); never auto-applied |
| **support now** | upstream ships information a user would want and we drop it | draft an implementation prompt + one-paragraph rationale, for the maintainer to accept or decline |
| **backlog** | real but not actionable yet | append a `docs/backlog.md` entry in that file's own format |
| **log only** | plumbing, ids, telemetry | tracker line only, so it is never re-litigated |

**Requirement.** Triage records a **frequency measurement** with every assignment —
"1 record in 1 of 80 sessions" for `cost-state`, "2 records in 13 sessions" for
copilot's `reasoningBlocks`. Today's `budget_usd` precedent (2 of 410 sessions) is why:
a field that looks transformative may occur almost never, and promoting on first sighting
wastes the maintainer's time.

**Requirement.** Triage must never assign a bucket from a field *name*. My
`SubAgentActivity` count was a substring grep and was wrong by ~20× (1561 lines claimed,
78 actual); it drove an "urgent" framing that a real count demoted to minor.

## 7. The tracker — append at discovery

This is the core of the request and the part that must not be compromised.

**Requirement.** A new machine-appendable log, `docs/agent-support/agent-format-tracker.jsonl`,
written **at the moment a finding is made**, not at the end of a pass. If the process dies
mid-run, everything discovered up to that instant is already on disk.

**Requirement: JSONL, not YAML.** Today's ledger edit merged two entries into one mapping
with duplicate `note:`/`verified:` keys. **YAML resolves duplicates by keeping the last,
so the file parsed cleanly while the newly written block was silently discarded.** A
"does it parse?" check passed it; only an assertion that history was intact caught it.
An append-only JSONL log cannot merge two records.

One record per finding:

```json
{
  "ts": "2026-08-31T17:27:53Z",
  "run_id": "20260831-172753Z",
  "agent": "copilot",
  "kind": "schema_drift",
  "field": "session.usage_checkpoint.data.promptCacheBreakState.models",
  "observation": "dict keyed by model id; observed key claude-haiku-4.5",
  "frequency": {"records": 1, "sessions": 1, "of_sessions": 13},
  "bucket": "urgent",
  "confidence": "verified",
  "evidence": ["scripts/probe_scan_output/agent_watch/20260831-172753Z-prebump/report.json"],
  "action_taken": "added to _NESTED_OPAQUE_KEYS[copilot] before baseline rebuild",
  "supersedes": null
}
```

**Requirement.** `confidence` is mandatory and has exactly two values: `verified` (a
command was run and its output is in `evidence`) or `assumed`. Today "opencode: vendor
outage" was recorded with the same authority as measured facts and was wrong; it took a
pass to correct. Had it been stamped `assumed`, the next pass would have known to re-test
rather than trust it.

**Requirement.** `supersedes` carries the `ts` of a record this one corrects. Corrections
are appended, never edited in place — three conclusions were revised today
(`SubAgentActivity` volume, opencode's cause, antigravity's cause) and the revision is
often more instructive than the original.

**Requirement.** The tracker is the **source**; `docs/agent-json-tracking.md` becomes a
rendered view of it. Nobody hand-writes both.

## 8. Subagents propose, one verifier applies

Subagents were the strongest part of today's run — three ran in parallel, and one
contradicted my own wrong number, which is precisely the value. But an autonomous fixer
is how the UUID leak ships.

**Requirement.** Subagents are read-only. They return a diff and its evidence; they do
not write to the repo, and they never run `xcodebuild` — the existing repo rule that
parallel edit-agents must not build.

**Requirement.** One serialized verifier applies accepted diffs and runs the suite once.
Test count is an invariant read from the result bundle, never from stdout, and must not
decrease.

**Requirement.** For **support now**, the output is a prompt plus a rationale of at most
one paragraph, stating what upstream now emits, how often, and what the user would see.
The maintainer accepts or declines; nothing is applied on their behalf.

## 9. Acceptance tests

1. **Tracker survives a kill.** Start a sweep, `SIGKILL` it mid-agent. Every finding
   logged before the kill is present and valid JSONL.
2. **Duplicate-merge is impossible.** Append two records with the same `run_id` and
   `agent`; both are present and readable. (The YAML failure cannot be reproduced.)
3. **Gate 1 holds.** Run unattended with a fixture gap containing a UUID-keyed map. The
   run stops before `--emit` and names the bucket. No fixture file is modified.
4. **Widened guard test.** Add a fixture record containing a model-slug-keyed dict. The
   fixture guard test fails. (It passes today — this is the hole.)
5. **Gate 2 evidence.** A bump proposal for an agent with a failed prebump prints
   `blockers` non-empty and refuses to offer the bump.
6. **Preflight batches.** With two agents unauthenticated, preflight reports both in one
   report before any agent work begins.
7. **Thin-store refusal.** With a `real_home_session` agent whose newest-5 union is
   below the thin gate, the run declines to generate a session and states why.
8. **Correction chain.** Append a finding, then a correction with `supersedes` set. The
   rendered view shows the correction and preserves the original.

## 10. Out of scope

- Any Swift change. Fixes to the app arising from triage are separate work.
- Replacing `docs/agent-support/agent-support-ledger.yml`. It stays the release-verified
  record; the tracker is the finding log. They answer different questions.
- Automating `steward_check.py`. Steward-owned agents follow §1g — ping, do not chase.
- Auto-installing beta builds to work around upstream bugs (openclaw's fix rides
  `2026.9.1-beta.1`; installing it unasked is not the sweep's call).

## 11. Honest limitations

- **This does not make the sweep correct, only unforgetful.** Three of today's
  conclusions were wrong on first pass. The tracker records wrongness faithfully; the
  `confidence` field and `supersedes` chain are the mitigation, not a cure.
- **Two gates is not zero.** The request was "as few asks as possible". Two per run is
  the floor I can defend, and §3 is the argument for why removing them costs more than
  they save. If they are removed anyway, do it knowingly.
- **The thin-sample weakness is untouched.** antigravity clears today because one real
  session exists; it will fail again the next time five thin sessions lead the window.
  The sampling fix is filed separately in `docs/backlog.md` and deliberately not folded
  in here.
- **Upstream release-note parsing will be unreliable.** Vendors do not publish schema
  changes. Today's Codex 0.151 subagent-identity move appeared in no release note; it was
  found by counting fields. Treat the online channel as a hint, never as the evidence.

## 12. Coordination

A parallel session owns Qwen work (`docs/superpowers/plans/2026-08-31-qwen-0.22-format-brief.md`)
and recently landed runway pricing (`c1dcb058`) and the CI test job (`5e4e59c7`). This
spec touches neither Swift nor CI. If it grows to, coordinate first — today two sessions
building the same project concurrently corrupted a module cache and produced two runs
that reported failures having executed zero tests.
