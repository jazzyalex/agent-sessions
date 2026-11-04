# Format-check reference: stewards

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

## 1f  Steward Check (what a community steward runs)

An agent may have a steward: a contributor who uses that agent regularly and re-verifies
its format a few times a year, or after a big vendor release. Maintained agents are checked
by the maintainer; best-effort agents have no steward yet. A steward is not expected to
know any of the above. They run one command:

```
./scripts/steward_check.py <agent>       # ./scripts/steward_check.py --list-agents
```

It runs the ordinary weekly scan (§1) restricted to that one agent, against the
steward's own local sessions, and answers in plain sentences with one of three
exits:

- **0 — all good.** `all good: <agent> format matches the baseline (N sessions
  sampled)`, plus the matrix's verified version. If their CLI is newer than the
  verified version and the schema still matches, it says the matrix entry can be
  bumped — that is the §1b evidence a maintainer needs.
- **1 — drift.** The schema diff in plain words, a **redacted** sample written to
  `scripts/probe_scan_output/steward_check/<agent>/redacted-sample/`, and a
  ready-to-paste GitHub issue body (also saved as `issue.md`).
- **2 — cannot check.** The CLI is not installed, there are no sessions on disk,
  or the repository has no baseline fixtures for that agent yet. Says which.

What it deliberately does **not** do: write or rebuild any baseline fixture.
Deciding that drift is real and rebuilding a baseline stays a maintainer job
(`scripts/rebuild_stage0_baseline.py --agent <agent> --emit`, §5/§7).

The sample reuses `rebuild_stage0_baseline._redact` — the same trimming that
produces committed fixtures — and then re-scans the result for home directories,
emails, key-shaped strings, IPs and long opaque ids. **If anything survives, the
sample is withheld entirely** and the issue body says so; a steward is never
handed an almost-clean file to paste into a public issue.

Maintainer side of the same command: when a steward's issue arrives, its sample
is already in fixture shape, so it drops straight into
`Resources/Fixtures/stage0/agents/<agent>/` for a baseline rebuild. Verify the
redaction yourself anyway before committing (§7).

---

## 1g  Agents With a Steward (what the maintainer does *not* chase)

`STEWARDS.md` assigns each agent a tier: **Maintained** (the maintainer runs it daily),
**Steward-verified** (a named contributor re-checks it on their own machine), or
**Best-effort** (nobody yet). A sweep must read that tier before deciding an agent is a
problem, because **the scan cannot distinguish "this agent is broken" from "this agent is
not installed here."** Both surface as `installed=unknown`, `latest_unknown`,
`cli_binary_unresolved`, or a discovery contract failing `no_local_file`.

For a **steward-verified** agent that is absent from this machine, all of those are the
expected, correct output. They are not findings. Do not:

- report them as drift, gaps, or open work in the sweep summary;
- install the CLI to "close" them — a maintainer install with no sessions in it produces
  no better evidence and starts a support obligation nobody asked for;
- bump or lower `max_verified_version` from a machine with no sessions from that build.
  The steward's dated verification *is* the evidence, and overwriting it with a local
  guess destroys the only real record.

What a sweep **does** owe a steward-verified agent, in order:

1. **State the tier next to the verdict.** "fx: `latest_unknown` — steward-verified,
   no local CLI" is a complete, honest line. "fx: `latest_unknown`" alone reads as a hole.
2. **Check the steward's date, not the schema.** The question is not "did the format
   move?" — nobody here can answer that — it is "how long since anyone who runs this
   agent looked?" Two or three checks a year is the agreed cadence; past that, the entry
   is aging, and *that* is the finding.
3. **Ping, don't investigate.** When it is due, or when upstream shipped a release the
   record predates, ask the steward to run `./scripts/steward_check.py <agent>`. That is
   a ten-minute job for them and an impossible one here.
4. **Route what you already know.** If the sweep saw something relevant — an upstream
   version the record predates, a contract that changed shape — put it in the ask so the
   steward is not re-deriving it.

**Read the recommendation through the tier.** The verdict vocabulary assumes the maintainer
can run the agent, so for a steward-owned one it gives advice you cannot take. Translate:
`blocked_no_fresh_evidence` / `rec=run_prebump_validator` on a steward agent does **not**
mean "run prebump" — no driver here can produce a session for a CLI that is not installed.
It means *upstream moved past what the steward last verified*, and the action is the ping in
step 3. Configure the agent's `upstream` source even when nothing else about it is
checkable locally: it is the **only** channel that can raise this, and without it the rule
above is unenforceable. fx sat at `upstream=unknown` for exactly this reason while v0.0.6
and v0.0.7 shipped past a record reading 0.0.5, and the sweep reported nothing.

A steward-verified agent only becomes maintainer work when its steward goes quiet. At
that point the honest move is to drop it to **Best-effort** in `STEWARDS.md` and say so,
not to quietly keep claiming a verification nobody performed.

**Ordering trap.** `STEWARDS.md` is the human table and the matrix is the machine record;
the file itself says the matrix wins on disagreement. But the *tier* lives only in
`STEWARDS.md` — the matrix has no `steward:` field — so a purely matrix-driven sweep is
structurally blind to stewardship and will keep re-reporting the same non-findings every
week. Read both, and if you find yourself about to file a steward-verified agent as a
gap, that is the bug.

---
